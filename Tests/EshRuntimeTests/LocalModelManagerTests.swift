import Foundation
import Network
import Testing
import EshCore
@testable import EshRuntime

// A tiny localhost HTTP server for deterministic download tests (no external network).
private final class TestHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    let port: UInt16
    private let body: Data
    private let contentLengthOverride: Int?   // if set, advertise this Content-Length (to force size mismatch)

    init(body: Data, contentLengthOverride: Int? = nil) throws {
        self.body = body
        self.contentLengthOverride = contentLengthOverride
        let params = NWParameters.tcp
        listener = try NWListener(using: params, on: .any)
        listener.newConnectionHandler = { [body, contentLengthOverride] conn in
            conn.start(queue: .global())
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                let len = contentLengthOverride ?? body.count
                let header = "HTTP/1.1 200 OK\r\nContent-Length: \(len)\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n"
                var out = Data(header.utf8); out.append(body)
                conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        let sem = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { sem.signal() } }
        listener.start(queue: .global())
        sem.wait()
        port = listener.port!.rawValue
    }
    func url(path: String = "/model.gguf") -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
    func stop() { listener.cancel() }
}

private struct FixedProfile: DeviceProfileProviding {
    let storage: UInt64?
    let physical: UInt64
    func currentProfile() -> DeviceProfile {
        DeviceProfile(platform: .iOS, physicalMemoryBytes: physical, availableMemoryBytes: physical / 2,
                      availableMemoryKind: .processAvailable, availableStorageBytes: storage,
                      thermalState: .nominal, lowPowerModeEnabled: false, supportsAppleFoundationModels: true,
                      osVersion: "test", deviceModel: "test")
    }
}

private func tempRoot() -> PersistenceRoot {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("esh-m8-\(UUID().uuidString)")
    return PersistenceRoot(rootURL: dir)
}

private func sha256Hex(_ d: Data) -> String {
    // reuse the manager's file hasher via a temp file to keep one implementation under test
    let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? d.write(to: u); defer { try? FileManager.default.removeItem(at: u) }
    return (try? LocalModelManager.sha256Hex(of: u)) ?? ""
}

private func descriptor(url: URL, bytes: Int64, sha: String, params: Double = 0.5) -> LocalModelDescriptor {
    LocalModelDescriptor(id: "test-model", displayName: "Test", sourceURL: url, repository: "test/repo",
                         license: "apache-2.0", expectedBytes: bytes, sha256: sha, quantization: "Q4_K_M",
                         parameterCountB: params, recommendedHardwareClass: "test")
}

@Suite
struct LocalModelManagerTests {

    @Test func catalogIsDataDrivenAndCurated() {
        #expect(LocalModelCatalog.models.count >= 2)
        #expect(LocalModelCatalog.descriptor(id: "qwen2.5-1.5b-instruct-q4km")?.sha256 == "1adf0b11065d8ad2e8123ea110d1ec956dab4ab038eab665614adba04b6c3370")
        #expect(LocalModelCatalog.models.allSatisfy { $0.license == "apache-2.0" && !$0.sha256.isEmpty && $0.expectedBytes > 0 })
    }

    @Test func installPlanRejectsInsufficientStorage() async {
        let mgr = LocalModelManager(root: tempRoot(), deviceProfileProvider: FixedProfile(storage: 10 * 1024 * 1024, physical: 8 << 30))
        let d = descriptor(url: URL(string: "http://127.0.0.1:1/x")!, bytes: 986_048_768, sha: "00")
        let plan = await mgr.installPlan(for: d)
        #expect(plan.storageSufficient == false)
        #expect(plan.suitable == false)
    }

    @Test func installFailsFastOnInsufficientStorage() async {
        let mgr = LocalModelManager(root: tempRoot(), deviceProfileProvider: FixedProfile(storage: 1 * 1024 * 1024, physical: 8 << 30))
        let d = descriptor(url: URL(string: "http://127.0.0.1:1/x")!, bytes: 986_048_768, sha: "00")
        await #expect(throws: LocalModelError.self) { _ = try await mgr.install(d) }
    }

    @Test func downloadVerifiesAndInstalls_thenRemoves() async throws {
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        let server = try TestHTTPServer(body: payload); defer { server.stop() }
        let root = tempRoot()
        let mgr = LocalModelManager(root: root, deviceProfileProvider: FixedProfile(storage: 8 << 30, physical: 8 << 30))
        let d = descriptor(url: server.url(), bytes: Int64(payload.count), sha: sha256Hex(payload))

        #expect(await mgr.state(for: d) == .notInstalled)
        let install = try await mgr.install(d)
        #expect(install.spec.backend == .gguf)
        #expect(await mgr.isInstalled(d.id))
        #expect(await mgr.state(for: d) == .installed)
        // File exists on disk at the recorded path
        #expect(FileManager.default.fileExists(atPath: install.installPath))

        // Duplicate install request → typed error
        await #expect(throws: LocalModelError.self) { _ = try await mgr.install(d) }

        // Remove → gone
        try await mgr.remove(d.id)
        #expect(await mgr.isInstalled(d.id) == false)
        #expect(await mgr.state(for: d) == .notInstalled)
        #expect(FileManager.default.fileExists(atPath: install.installPath) == false)
    }

    @Test func checksumMismatchIsRejected() async throws {
        let payload = Data((0..<50_000).map { UInt8($0 % 251) })
        let server = try TestHTTPServer(body: payload); defer { server.stop() }
        let mgr = LocalModelManager(root: tempRoot(), deviceProfileProvider: FixedProfile(storage: 8 << 30, physical: 8 << 30))
        // Correct length, WRONG sha → checksum mismatch, not installed.
        let d = descriptor(url: server.url(), bytes: Int64(payload.count), sha: String(repeating: "a", count: 64))
        await #expect(throws: LocalModelError.self) { _ = try await mgr.install(d) }
        #expect(await mgr.isInstalled(d.id) == false)
    }

    @Test func contentLengthMismatchIsRejected() async throws {
        let payload = Data((0..<50_000).map { UInt8($0 % 251) })
        // Advertise more bytes than we send → size mismatch.
        let server = try TestHTTPServer(body: payload, contentLengthOverride: payload.count + 10_000); defer { server.stop() }
        let mgr = LocalModelManager(root: tempRoot(), deviceProfileProvider: FixedProfile(storage: 8 << 30, physical: 8 << 30))
        let d = descriptor(url: server.url(), bytes: Int64(payload.count) + 10_000, sha: sha256Hex(payload))
        await #expect(throws: Error.self) { _ = try await mgr.install(d) }
        #expect(await mgr.isInstalled(d.id) == false)
    }

    @Test func installRecordWithoutFileIsNotInstalled() async throws {
        let root = tempRoot()
        let store = FileModelStore(root: root)
        let d = LocalModelCatalog.descriptor(id: "qwen2.5-0.5b-instruct-q4km")!
        // Save a record but do NOT create the model file.
        try store.save(manifest: ModelManifest(install: ModelInstall(id: d.id, spec: d.makeSpec(), installPath: "/nope/model.gguf", sizeBytes: d.expectedBytes, backendFormat: "gguf"), files: ["model.gguf"]))
        let mgr = LocalModelManager(root: root, deviceProfileProvider: FixedProfile(storage: 8 << 30, physical: 8 << 30))
        #expect(await mgr.isInstalled(d.id) == false)   // record present but file missing → not installed
    }

    @Test func removeNonInstalledThrows() async {
        let mgr = LocalModelManager(root: tempRoot(), deviceProfileProvider: FixedProfile(storage: 8 << 30, physical: 8 << 30))
        await #expect(throws: LocalModelError.self) { try await mgr.remove("nope") }
    }
}
