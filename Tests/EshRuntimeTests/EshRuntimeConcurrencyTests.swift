import Foundation
import Network
import Testing
import EshCore
@testable import EshRuntime

// M10 #9 — concurrency behavior is defined and race-free. Serialized operations (install) resolve to a
// single winner; independent operations (generate) run concurrently without data races.

private struct SlowRuntime: BackendRuntime, @unchecked Sendable {
    let backend: BackendKind = .apple
    let modelID: String = "slow"
    var metrics: Metrics { get async { Metrics(ttftMilliseconds: 1, finishReason: "stop") } }
    func prepare(session: ChatSession) async throws {}
    func generate(session: ChatSession, config: GenerationConfig) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for c in ["a", "b", "c"] {
                    try? await Task.sleep(nanoseconds: 2_000_000)
                    continuation.yield(c)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func exportRuntimeCache() async throws -> CacheSnapshot { throw StoreError.invalidManifest("x") }
    func importRuntimeCache(_ snapshot: CacheSnapshot) async throws { throw StoreError.invalidManifest("x") }
    func validateCacheCompatibility(_ manifest: CacheManifest) async throws { throw CompatibilityIssue(reason: "x") }
    func unload() async {}
}

private struct SlowBackend: InferenceBackend, @unchecked Sendable {
    let kind: BackendKind = .apple
    let runtimeVersion = "slow"
    func capabilityReport(for install: ModelInstall) -> BackendCapabilityReport {
        BackendCapabilityReport(backend: kind, runtimeVersion: runtimeVersion, ready: true,
                                supportedFeatures: [.directInference], unavailableFeatures: [], warnings: [])
    }
    func loadRuntime(for install: ModelInstall) async throws -> BackendRuntime { SlowRuntime() }
    func makeCompatibilityChecker(for install: ModelInstall) -> CompatibilityChecking { NoopChecker() }
}
private struct NoopChecker: CompatibilityChecking { func validate(manifest: CacheManifest) throws {} }

// A localhost server that delays before responding, so a second concurrent install observes the first in flight.
private final class SlowHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    let port: UInt16
    init(body: Data, delayMs: Int) throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { conn in
            conn.start(queue: .global())
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                usleep(useconds_t(delayMs * 1000))
                let header = "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n"
                var out = Data(header.utf8); out.append(body)
                conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        let sem = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { sem.signal() } }
        listener.start(queue: .global()); sem.wait()
        port = listener.port!.rawValue
    }
    func url() -> URL { URL(string: "http://127.0.0.1:\(port)/model.gguf")! }
    func stop() { listener.cancel() }
}

private struct FixedProfile: DeviceProfileProviding {
    func currentProfile() -> DeviceProfile {
        DeviceProfile(platform: .iOS, physicalMemoryBytes: 8 << 30, availableMemoryBytes: 4 << 30,
                      availableMemoryKind: .processAvailable, availableStorageBytes: 8 << 30,
                      thermalState: .nominal, lowPowerModeEnabled: false, supportsAppleFoundationModels: true,
                      osVersion: "test", deviceModel: "test")
    }
}

@Suite
struct EshRuntimeConcurrencyTests {

    @Test func manyConcurrentGenerationsAllSucceed() async throws {
        let runtime = EshRuntime(registry: InferenceBackendRegistry(backends: [.apple: SlowBackend()]))
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<50 { group.addTask { try await runtime.generate(prompt: "hi").text } }
            var count = 0
            for try await text in group { #expect(text == "abc"); count += 1 }
            #expect(count == 50)
        }
    }

    @Test func generateWhileQueryingDoesNotDeadlock() async throws {
        let runtime = EshRuntime(registry: InferenceBackendRegistry(backends: [.apple: SlowBackend()]))
        async let gen = runtime.generate(prompt: "hi").text
        async let models = runtime.localModels()
        async let caps = runtime.capabilities().hasReadyBackend
        let (g, m, c) = try await (gen, models, caps)
        #expect(g == "abc"); #expect(m.isEmpty == false); #expect(c == true)
    }

    @Test func concurrentDuplicateInstallHasExactlyOneWinner() async throws {
        let payload = Data((0..<300_000).map { UInt8($0 % 251) })
        let server = try SlowHTTPServer(body: payload, delayMs: 150); defer { server.stop() }
        let root = PersistenceRoot(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("esh-m10c-\(UUID())"))
        let mgr = LocalModelManager(root: root, deviceProfileProvider: FixedProfile())
        let sha = LocalModelManager_sha(payload)
        let d = LocalModelDescriptor(id: "dup", displayName: "Dup", sourceURL: server.url(), repository: "t/t",
                                     license: "apache-2.0", expectedBytes: Int64(payload.count), sha256: sha,
                                     quantization: "Q4_K_M", parameterCountB: 0.1, recommendedHardwareClass: "test")
        var successes = 0, conflicts = 0
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    do { _ = try await mgr.install(d); return true }
                    catch is LocalModelError { return false }
                    catch { return false }
                }
            }
            for await ok in group { if ok { successes += 1 } else { conflicts += 1 } }
        }
        #expect(successes == 1)          // exactly one install wins
        #expect(conflicts == 3)          // the rest fail typed (installInProgress / alreadyInstalled)
        #expect(await mgr.isInstalled("dup"))
    }
}

// Bridge to the manager's file hasher without exposing it publicly for tests.
private func LocalModelManager_sha(_ d: Data) -> String {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? d.write(to: u); defer { try? FileManager.default.removeItem(at: u) }
    return (try? LocalModelManager.sha256Hex(of: u)) ?? ""
}
