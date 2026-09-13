import Foundation
import Testing
import EshCore
@testable import EshRuntime

// A deterministic in-memory backend so the facade can be tested without Apple FM / MLX / GGUF.
private struct MockRuntime: BackendRuntime, @unchecked Sendable {
    let backend: BackendKind
    let modelID: String
    let chunks: [String]
    let perChunkSleepNs: UInt64
    var metrics: Metrics { get async { Metrics(ttftMilliseconds: 1, finishReason: "stop") } }

    func prepare(session: ChatSession) async throws {}
    func generate(session: ChatSession, config: GenerationConfig) -> AsyncThrowingStream<String, Error> {
        let chunks = self.chunks
        let sleep = self.perChunkSleepNs
        let echo = session.messages.last?.text ?? ""
        return AsyncThrowingStream { continuation in
            let task = Task {
                for c in chunks {
                    if sleep > 0 { try await Task.sleep(nanoseconds: sleep) }
                    continuation.yield(c == "<echo>" ? echo : c)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func exportRuntimeCache() async throws -> CacheSnapshot { throw StoreError.invalidManifest("mock") }
    func importRuntimeCache(_ snapshot: CacheSnapshot) async throws { throw StoreError.invalidManifest("mock") }
    func validateCacheCompatibility(_ manifest: CacheManifest) async throws { throw CompatibilityIssue(reason: "mock") }
    func unload() async {}
}

private struct MockChecker: CompatibilityChecking {
    func validate(manifest: CacheManifest) throws { throw CompatibilityIssue(reason: "mock") }
}

private struct MockBackend: InferenceBackend, @unchecked Sendable {
    let kind: BackendKind
    let runtimeVersion: String = "mock-v1"
    var ready: Bool = true
    var chunks: [String] = ["MOCK:", "<echo>"]
    var perChunkSleepNs: UInt64 = 0

    func capabilityReport(for install: ModelInstall) -> BackendCapabilityReport {
        BackendCapabilityReport(backend: kind, runtimeVersion: runtimeVersion, ready: ready,
                                supportedFeatures: ready ? [.directInference] : [],
                                unavailableFeatures: ready ? [] : [.init(feature: .directInference, reason: "mock not ready")],
                                warnings: ready ? [] : ["mock not ready"])
    }
    func loadRuntime(for install: ModelInstall) async throws -> BackendRuntime {
        MockRuntime(backend: kind, modelID: install.id, chunks: chunks, perChunkSleepNs: perChunkSleepNs)
    }
    func makeCompatibilityChecker(for install: ModelInstall) -> CompatibilityChecking { MockChecker() }
}

private func mlxInstall(id: String) -> ModelInstall {
    ModelInstall(id: id, spec: ModelSpec(id: id, displayName: id, backend: .mlx,
                                         source: ModelSource(kind: .localPath, reference: id)),
                 installPath: "/tmp/\(id)", sizeBytes: 1, backendFormat: "mlx", runtimeVersion: "mlx")
}

@Suite
struct EshRuntimeTests {

    // Auto: with only a (mock) Apple backend wired, Auto selects it and returns it in the result metadata.
    @Test
    func autoSelectsTheOnlyWiredBackendAndReturnsMetadata() async throws {
        let registry = InferenceBackendRegistry(backends: [.apple: MockBackend(kind: .apple)])
        let runtime = EshRuntime(registry: registry)
        let result = try await runtime.generate(prompt: "ping")
        #expect(result.text == "MOCK:ping")
        #expect(result.selection.backend == .apple)
        #expect(result.selection.modelID == AppleProvider.canonicalModelID)
        #expect(result.selection.localOnlySatisfied)
        #expect(result.selection.reason.isEmpty == false)
        #expect(result.metrics.finishReason == "stop")
    }

    // Explicit Apple pin is honored.
    @Test
    func explicitApplePinIsHonored() async throws {
        let registry = InferenceBackendRegistry(backends: [.apple: MockBackend(kind: .apple)])
        let runtime = EshRuntime(registry: registry)
        let req = EshGenerationRequest(prompt: "hi", constraints: .pinned(AppleProvider.canonicalModelID))
        let result = try await runtime.generate(req)
        #expect(result.selection.backend == .apple)
        #expect(result.selection.reason.contains("Apple"))
    }

    // A pinned non-Apple model that is not installed is NEVER substituted with Apple — it fails typed.
    @Test
    func pinnedUninstalledModelIsNotSubstitutedWithApple() async throws {
        let registry = InferenceBackendRegistry(backends: [.apple: MockBackend(kind: .apple)])
        let runtime = EshRuntime(registry: registry)
        let req = EshGenerationRequest(prompt: "hi", constraints: .pinned("mlx-community/some-model"))
        await #expect(throws: EshRuntimeError.self) {
            _ = try await runtime.generate(req)
        }
    }

    // A pinned model whose backend is not wired on this platform fails typed (no Apple substitution).
    @Test
    func pinnedModelWithUnwiredBackendFailsTyped() async throws {
        // Apple-only assembly (iOS-like), but the model is installed as an MLX model.
        let registry = InferenceBackendRegistry(backends: [.apple: MockBackend(kind: .apple)])
        let runtime = EshRuntime(registry: registry, installProvider: StaticInstallProvider([mlxInstall(id: "m1")]))
        do {
            _ = try await runtime.generate(EshGenerationRequest(prompt: "x", constraints: .pinned("m1")))
            Issue.record("expected a typed error")
        } catch let error as EshRuntimeError {
            #expect(error == .backendUnavailable(.mlx, reason: "the backend for pinned model 'm1' is not available on this platform."))
        }
    }

    // Auto prefers Apple even when an installed non-Apple model exists (zero-download on-device).
    @Test
    func autoPrefersAppleOverInstalledModel() async throws {
        let registry = InferenceBackendRegistry(backends: [.apple: MockBackend(kind: .apple), .mlx: MockBackend(kind: .mlx)])
        let runtime = EshRuntime(registry: registry, installProvider: StaticInstallProvider([mlxInstall(id: "m1")]))
        let result = try await runtime.generate(prompt: "hey")
        #expect(result.selection.backend == .apple)
    }

    // No wired backend → honest typed error.
    @Test
    func noWiredBackendThrows() async throws {
        let runtime = EshRuntime(registry: InferenceBackendRegistry(backends: [:]))
        await #expect(throws: EshRuntimeError.self) { _ = try await runtime.generate(prompt: "x") }
    }

    // localOnly is satisfied by the (local) backends esh ships; selection records it.
    @Test
    func localOnlyIsSatisfiedByLocalBackend() async throws {
        let registry = InferenceBackendRegistry(backends: [.apple: MockBackend(kind: .apple)])
        let runtime = EshRuntime(registry: registry)
        let result = try await runtime.generate(EshGenerationRequest(prompt: "x", constraints: .localOnly))
        #expect(result.selection.localOnlySatisfied)
    }

    // capabilities() reports the wired backends and their readiness.
    @Test
    func capabilitiesReportsWiredBackends() async {
        let registry = InferenceBackendRegistry(backends: [.apple: MockBackend(kind: .apple, ready: true)])
        let runtime = EshRuntime(registry: registry)
        let snap = await runtime.capabilities()
        #expect(snap.backends.contains { $0.backend == .apple && $0.report.ready })
        #expect(snap.hasReadyBackend)
        #expect(snap.backends.allSatisfy { $0.isLocal })
    }

    // Streaming yields token events then a completed event with the final result.
    @Test
    func streamEmitsTokensThenCompleted() async throws {
        let registry = InferenceBackendRegistry(backends: [.apple: MockBackend(kind: .apple, chunks: ["a", "b", "c"])])
        let runtime = EshRuntime(registry: registry)
        var tokens: [String] = []
        var completed: EshGenerationResult?
        for try await event in runtime.stream(EshGenerationRequest(prompt: "x")) {
            switch event {
            case .token(let t): tokens.append(t)
            case .completed(let r): completed = r
            }
        }
        #expect(tokens == ["a", "b", "c"])
        #expect(completed?.text == "abc")
        #expect(completed?.selection.backend == .apple)
    }

    // Cancellation propagates: cancelling the consuming task stops generation.
    @Test
    func cancellationPropagates() async throws {
        // Many chunks with a per-chunk delay so cancellation is observed mid-stream.
        let backend = MockBackend(kind: .apple, chunks: Array(repeating: "x", count: 100), perChunkSleepNs: 20_000_000)
        let registry = InferenceBackendRegistry(backends: [.apple: backend])
        let runtime = EshRuntime(registry: registry)
        let task = Task { try await runtime.generate(prompt: "x") }
        // Let it start, then cancel.
        try await Task.sleep(nanoseconds: 30_000_000)
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}
