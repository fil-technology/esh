import Foundation
import Testing
import EshCore
@testable import EshRuntime

// M10 #6 — generation lifecycle stress at the SDK level (deterministic mock backend). Real-backend
// throughput/thermal stress is device work (see docs/PRODUCTION_READINESS.md); this proves the facade
// itself does not hang, leak task state, or get stuck after many sequential runs and repeated cancellation.

private struct StreamRuntime: BackendRuntime, @unchecked Sendable {
    let backend: BackendKind = .apple
    let modelID = "stress"
    var metrics: Metrics { get async { Metrics(ttftMilliseconds: 1, finishReason: "stop") } }
    func prepare(session: ChatSession) async throws {}
    func generate(session: ChatSession, config: GenerationConfig) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for i in 0..<20 {
                    try? await Task.sleep(nanoseconds: 1_000_000)
                    if Task.isCancelled { continuation.finish(); return }
                    continuation.yield("t\(i)")
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
private struct StreamBackend: InferenceBackend, @unchecked Sendable {
    let kind: BackendKind = .apple
    let runtimeVersion = "stress"
    func capabilityReport(for install: ModelInstall) -> BackendCapabilityReport {
        BackendCapabilityReport(backend: kind, runtimeVersion: runtimeVersion, ready: true,
                                supportedFeatures: [.directInference], unavailableFeatures: [], warnings: [])
    }
    func loadRuntime(for install: ModelInstall) async throws -> BackendRuntime { StreamRuntime() }
    func makeCompatibilityChecker(for install: ModelInstall) -> CompatibilityChecking { Chk() }
}
private struct Chk: CompatibilityChecking { func validate(manifest: CacheManifest) throws {} }

@Suite
struct LifecycleStressTests {

    @Test func hundredSequentialGenerationsStayHealthy() async throws {
        let runtime = EshRuntime(registry: InferenceBackendRegistry(backends: [.apple: StreamBackend()]))
        for _ in 0..<100 {
            let r = try await runtime.generate(prompt: "hi")
            #expect(r.text.isEmpty == false)
        }
        // Still healthy after the run.
        #expect(try await runtime.generate(prompt: "hi").text.isEmpty == false)
    }

    @Test func repeatedCancelThenRestartRecovers() async throws {
        let runtime = EshRuntime(registry: InferenceBackendRegistry(backends: [.apple: StreamBackend()]))
        for _ in 0..<25 {
            let task = Task { try await runtime.generate(prompt: "hi") }
            try? await Task.sleep(nanoseconds: 2_000_000)   // let it start
            task.cancel()
            _ = try? await task.value                        // cancelled or completed — both fine
        }
        // After many cancellations the runtime still produces a full result (no stuck/stale state).
        let r = try await runtime.generate(prompt: "hi")
        #expect(r.text.isEmpty == false)
    }

    @Test func streamCancellationStopsAndStaysUsable() async throws {
        let runtime = EshRuntime(registry: InferenceBackendRegistry(backends: [.apple: StreamBackend()]))
        let stream = runtime.stream(EshGenerationRequest(prompt: "hi"))
        var seen = 0
        for try await ev in stream { if case .token = ev { seen += 1; if seen >= 2 { break } } }  // cancel early
        #expect(seen >= 1)
        // Runtime is reusable immediately after an interrupted stream.
        let r = try await runtime.generate(prompt: "again")
        #expect(r.text.isEmpty == false)
    }
}
