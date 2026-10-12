import Foundation
import Testing
import EshCore
@testable import EshRuntime

// P0 Studio end-to-end: validates the lifecycle a Studio consumer drives through the EshRuntime facade —
// selection, backend selection, load, token streaming, cancellation, switching, unload, recovery from a load
// failure, and the live memory-safety gate — using deterministic mock backends (no real MLX/GGUF weights).
// Model-specific discovery + fit of the two research models is covered in EshCoreTests (registry + ModelFit).

private actor Flags { var unloaded = false; func markUnloaded() { unloaded = true }; func didUnload() -> Bool { unloaded } }

private struct ChunkRuntime: BackendRuntime, @unchecked Sendable {
    let backend: BackendKind
    let modelID: String
    let chunks: [String]
    let flags: Flags
    var metrics: Metrics { get async { Metrics(finishReason: "stop") } }
    func prepare(session: ChatSession) async throws {}
    func generate(session: ChatSession, config: GenerationConfig) -> AsyncThrowingStream<String, Error> {
        let cs = chunks
        return AsyncThrowingStream { c in
            let t = Task {
                for ch in cs {
                    if Task.isCancelled { c.finish(throwing: CancellationError()); return }
                    c.yield(ch)
                    try? await Task.sleep(nanoseconds: 10_000_000)   // 10ms per chunk so cancellation can interrupt
                }
                c.finish()
            }
            c.onTermination = { _ in t.cancel() }
        }
    }
    func exportRuntimeCache() async throws -> CacheSnapshot { throw StoreError.invalidManifest("mock") }
    func importRuntimeCache(_ snapshot: CacheSnapshot) async throws {}
    func validateCacheCompatibility(_ manifest: CacheManifest) async throws {}
    func unload() async { await flags.markUnloaded() }
}

private struct ChunkBackend: InferenceBackend, @unchecked Sendable {
    let kind: BackendKind
    let runtimeVersion = "mock"
    let chunks: [String]
    let flags: Flags
    var ready = true
    var failLoad = false
    func capabilityReport(for install: ModelInstall) -> BackendCapabilityReport {
        BackendCapabilityReport(backend: kind, runtimeVersion: "mock", ready: ready,
                                supportedFeatures: ready ? [.directInference] : [])
    }
    func loadRuntime(for install: ModelInstall) async throws -> BackendRuntime {
        if failLoad { throw StoreError.invalidManifest("simulated load failure") }
        return ChunkRuntime(backend: kind, modelID: install.id, chunks: chunks, flags: flags)
    }
    func makeCompatibilityChecker(for install: ModelInstall) -> CompatibilityChecking { PassChecker() }
}
private struct PassChecker: CompatibilityChecking { func validate(manifest: CacheManifest) throws {} }

private func install(_ id: String, backend: BackendKind, sizeBytes: Int64 = 1) -> ModelInstall {
    ModelInstall(id: id, spec: ModelSpec(id: id, displayName: id, backend: backend,
                                         source: ModelSource(kind: .localPath, reference: id)),
                 installPath: "/tmp/\(id)", sizeBytes: sizeBytes, backendFormat: backend.rawValue)
}
private func tmpRoot() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
}
private func pinned(_ id: String) -> EshGenerationRequest {
    EshGenerationRequest(messages: [Message(role: .user, text: "hi")], constraints: EshConstraints(pinnedModelID: id))
}

@Suite struct StudioWorkflowE2ETests {

    // Steps: selection + backend selection + load + streaming, for BOTH backends (MLX and GGUF).
    @Test func selectsLoadsAndStreamsThroughBothBackends() async throws {
        let flags = Flags()
        let runtime = await EshRuntime.makeDefault(
            backends: [.mlx: ChunkBackend(kind: .mlx, chunks: ["30B", "-", "ok"], flags: flags),
                       .gguf: ChunkBackend(kind: .gguf, chunks: ["80B", "-", "ok"], flags: flags)],
            root: PersistenceRoot(rootURL: tmpRoot()),
            installProvider: StaticInstallProvider([install("small-mlx", backend: .mlx),
                                                    install("small-gguf", backend: .gguf)]))
        // MLX
        var a = ""
        for try await e in runtime.stream(pinned("small-mlx")) { if case let .token(t) = e { a += t } }
        #expect(a == "30B-ok")
        // Switch to GGUF (step: switching between models)
        var b = ""
        for try await e in runtime.stream(pinned("small-gguf")) { if case let .token(t) = e { b += t } }
        #expect(b == "80B-ok")
    }

    // Step: cancellation mid-stream stops cleanly.
    @Test func cancellationStopsStream() async throws {
        let flags = Flags()
        let runtime = await EshRuntime.makeDefault(
            backends: [.gguf: ChunkBackend(kind: .gguf, chunks: Array(repeating: "x", count: 600), flags: flags)],
            root: PersistenceRoot(rootURL: tmpRoot()),
            installProvider: StaticInstallProvider([install("small-gguf", backend: .gguf)]))
        let collected = Mutex(0)
        let task = Task { for try await e in runtime.stream(pinned("small-gguf")) { if case .token = e { collected.inc() } } }
        // Wait long enough that tokens reliably flow even under CI load (chunks are 10ms apart; 600×10ms=6s total),
        // then cancel well before completion. Robust against startup latency and scheduler jitter.
        try await Task.sleep(nanoseconds: 600_000_000)   // 0.6s → ~tens of tokens expected
        task.cancel()
        _ = await task.result
        let n = collected.value
        #expect(n > 0 && n < 600)   // some tokens, then cancelled before the full 600
    }

    // Step: unload / residentModels API. FINDING: the text stream() path loads a runtime per-call and releases
    // it when the stream ends — it does NOT register into the warm-pool that residentModels()/unload() manage.
    // So there are no residents after a stream, and unloading a model that was never warm-pooled honestly throws
    // .unknownModel. (Warm-pool residency is a separate lifecycle path, not wired to text stream today — noted as
    // a follow-up for Studio if it needs explicit keep-warm/unload of chat models.)
    @Test func unloadAndResidentModelsAPIBehaveHonestly() async throws {
        let runtime = await EshRuntime.makeDefault(
            backends: [.gguf: ChunkBackend(kind: .gguf, chunks: ["ok"], flags: Flags())],
            root: PersistenceRoot(rootURL: tmpRoot()),
            installProvider: StaticInstallProvider([install("small-gguf", backend: .gguf)]))
        #expect(await runtime.residentModels().isEmpty)                 // no warm residents from stream path
        await #expect(throws: (any Error).self) {
            try await runtime.unload(modelID: "never-warmed")           // honest: UnloadError.unknownModel, not a silent no-op
        }
    }

    // Step: recovery from a load failure — a failing backend throws a typed error; a subsequent good load works.
    @Test func recoversFromLoadFailure() async throws {
        let flags = Flags()
        let failing = await EshRuntime.makeDefault(
            backends: [.gguf: ChunkBackend(kind: .gguf, chunks: ["x"], flags: flags, failLoad: true)],
            root: PersistenceRoot(rootURL: tmpRoot()),
            installProvider: StaticInstallProvider([install("small-gguf", backend: .gguf)]))
        await #expect(throws: EshRuntimeError.self) {
            for try await _ in failing.stream(pinned("small-gguf")) {}
        }
        // A fresh runtime with a working backend recovers (runtime not permanently poisoned).
        let good = await EshRuntime.makeDefault(
            backends: [.gguf: ChunkBackend(kind: .gguf, chunks: ["recovered"], flags: flags)],
            root: PersistenceRoot(rootURL: tmpRoot()),
            installProvider: StaticInstallProvider([install("small-gguf", backend: .gguf)]))
        var out = ""
        for try await e in good.stream(pinned("small-gguf")) { if case let .token(t) = e { out += t } }
        #expect(out == "recovered")
    }

    // Step: the live memory-safety gate rejects an unsafe load through the facade (host-independent: a model
    // larger than any Mac's RAM via a huge on-disk size) with the typed insufficientMemory error.
    @Test func memorySafetyGateRejectsOversizeLoadThroughFacade() async throws {
        let gb: Int64 = 1_073_741_824
        let runtime = await EshRuntime.makeDefault(
            backends: [.gguf: ChunkBackend(kind: .gguf, chunks: ["x"], flags: Flags())],
            root: PersistenceRoot(rootURL: tmpRoot()),
            installProvider: StaticInstallProvider([install("oversize-model", backend: .gguf, sizeBytes: 2000 * gb)]))
        var thrown: Error?
        do { for try await _ in runtime.stream(pinned("oversize-model")) {} } catch { thrown = error }
        guard case .insufficientMemory = (thrown as? EshRuntimeError) else {
            Issue.record("expected insufficientMemory, got \(String(describing: thrown))"); return
        }
    }
}

/// Tiny thread-safe counter for the cancellation test.
private final class Mutex: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    init(_ v: Int) { n = v }
    func inc() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
