import Foundation
import Testing
import EshCore
@testable import EshRuntime

// M10 #4 — every production-relevant generation failure surfaces as a typed EshRuntimeError (or
// CancellationError), never an arbitrary string the host must parse.

private struct ThrowingLoadBackend: InferenceBackend, @unchecked Sendable {
    let kind: BackendKind = .apple
    let runtimeVersion = "throw-load"
    func capabilityReport(for install: ModelInstall) -> BackendCapabilityReport {
        BackendCapabilityReport(backend: kind, runtimeVersion: runtimeVersion, ready: true,
                                supportedFeatures: [.directInference], unavailableFeatures: [], warnings: [])
    }
    func loadRuntime(for install: ModelInstall) async throws -> BackendRuntime {
        throw StoreError.invalidManifest("weights corrupt")
    }
    func makeCompatibilityChecker(for install: ModelInstall) -> CompatibilityChecking { NoChecker() }
}

private struct MidStreamThrowRuntime: BackendRuntime, @unchecked Sendable {
    let backend: BackendKind = .apple
    let modelID: String = "throw"
    var metrics: Metrics { get async { Metrics(ttftMilliseconds: 1, finishReason: "error") } }
    func prepare(session: ChatSession) async throws {}
    func generate(session: ChatSession, config: GenerationConfig) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("partial ")
            continuation.finish(throwing: StoreError.invalidManifest("decode blew up"))
        }
    }
    func exportRuntimeCache() async throws -> CacheSnapshot { throw StoreError.invalidManifest("x") }
    func importRuntimeCache(_ snapshot: CacheSnapshot) async throws { throw StoreError.invalidManifest("x") }
    func validateCacheCompatibility(_ manifest: CacheManifest) async throws { throw CompatibilityIssue(reason: "x") }
    func unload() async {}
}

private struct MidStreamThrowBackend: InferenceBackend, @unchecked Sendable {
    let kind: BackendKind = .apple
    let runtimeVersion = "throw-stream"
    func capabilityReport(for install: ModelInstall) -> BackendCapabilityReport {
        BackendCapabilityReport(backend: kind, runtimeVersion: runtimeVersion, ready: true,
                                supportedFeatures: [.directInference], unavailableFeatures: [], warnings: [])
    }
    func loadRuntime(for install: ModelInstall) async throws -> BackendRuntime { MidStreamThrowRuntime() }
    func makeCompatibilityChecker(for install: ModelInstall) -> CompatibilityChecking { NoChecker() }
}

private struct NoChecker: CompatibilityChecking {
    func validate(manifest: CacheManifest) throws {}
}

@Suite
struct EshRuntimeErrorTests {

    @Test func modelLoadFailureSurfacesTyped() async {
        let runtime = EshRuntime(registry: InferenceBackendRegistry(backends: [.apple: ThrowingLoadBackend()]))
        do {
            _ = try await runtime.generate(prompt: "hi")
            Issue.record("expected modelLoadFailed")
        } catch let e as EshRuntimeError {
            guard case .modelLoadFailed = e else { Issue.record("wrong case: \(e)"); return }
        } catch { Issue.record("wrong error type: \(error)") }
    }

    @Test func midStreamFailureSurfacesTyped() async {
        let runtime = EshRuntime(registry: InferenceBackendRegistry(backends: [.apple: MidStreamThrowBackend()]))
        do {
            _ = try await runtime.generate(prompt: "hi")
            Issue.record("expected generationFailed")
        } catch let e as EshRuntimeError {
            guard case .generationFailed = e else { Issue.record("wrong case: \(e)"); return }
        } catch { Issue.record("wrong error type: \(error)") }
    }

    @Test func noBackendSurfacesTyped() async {
        let runtime = EshRuntime(registry: InferenceBackendRegistry(backends: [:]))
        await #expect(throws: EshRuntimeError.self) { _ = try await runtime.generate(prompt: "hi") }
    }

    @Test func everyErrorCaseHasDisplayText() {
        let cases: [EshRuntimeError] = [
            .noAvailableBackend(reason: "x"), .pinnedModelUnavailable(modelID: "m", reason: "x"),
            .backendUnavailable(.gguf, reason: "x"), .localOnlyViolation(reason: "x"),
            .unsupportedDevice(reason: "x"), .modelLoadFailed(modelID: "m", reason: "x"),
            .generationFailed(reason: "x"),
        ]
        for c in cases { #expect((c.errorDescription ?? "").isEmpty == false) }
    }
}
