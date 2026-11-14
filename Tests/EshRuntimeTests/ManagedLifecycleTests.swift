import Foundation
import Testing
import EshCore
@testable import EshRuntime

// Managed SDK inference (Phase 2/5), tested against the PUBLIC facade with deterministic mock backends so it runs in
// CI without model weights. Real-model coverage (llama.cpp memory, SDK vs serve) lives in EshLlamaCppTests.

private actor Ledger {
    var loads: [String: Int] = [:]
    var unloads: [String: Int] = [:]
    var inFlight = 0
    var maxInFlight = 0
    func loaded(_ id: String) { loads[id, default: 0] += 1 }
    func unloaded(_ id: String) { unloads[id, default: 0] += 1 }
    func begin() { inFlight += 1; maxInFlight = max(maxInFlight, inFlight) }
    func end() { inFlight -= 1 }
    func loadCount(_ id: String) -> Int { loads[id] ?? 0 }
    func unloadCount(_ id: String) -> Int { unloads[id] ?? 0 }
    func peakConcurrency() -> Int { maxInFlight }
}

private final class MockRuntime: BackendRuntime, @unchecked Sendable {
    let backend: BackendKind
    let modelID: String
    let ledger: Ledger
    let chunks: Int
    let delayNanos: UInt64
    init(backend: BackendKind, modelID: String, ledger: Ledger, chunks: Int, delayNanos: UInt64) {
        self.backend = backend; self.modelID = modelID; self.ledger = ledger; self.chunks = chunks; self.delayNanos = delayNanos
    }
    var metrics: Metrics { get async { Metrics(memoryBytes: 123_000_000, finishReason: "stop") } }
    func prepare(session: ChatSession) async throws {}
    func generate(session: ChatSession, config: GenerationConfig) -> AsyncThrowingStream<String, Error> {
        let ledger = self.ledger, n = chunks, delay = delayNanos
        // Echo the last user message so session isolation is observable.
        let echo = session.messages.last(where: { $0.role == .user })?.text ?? ""
        return AsyncThrowingStream { c in
            let t = Task {
                await ledger.begin()
                for i in 0..<n {
                    if Task.isCancelled { await ledger.end(); c.finish(throwing: CancellationError()); return }
                    c.yield(i == 0 ? "[\(echo)]" : ".")
                    try? await Task.sleep(nanoseconds: delay)
                }
                await ledger.end()
                c.finish()
            }
            c.onTermination = { _ in t.cancel() }
        }
    }
    func exportRuntimeCache() async throws -> CacheSnapshot { throw StoreError.invalidManifest("mock") }
    func importRuntimeCache(_ snapshot: CacheSnapshot) async throws {}
    func validateCacheCompatibility(_ manifest: CacheManifest) async throws {}
    func unload() async { await ledger.unloaded(modelID) }
}

private struct MockBackend: InferenceBackend, BackendLifecycleDescribing, @unchecked Sendable {
    let kind: BackendKind
    let runtimeVersion = "mock"
    let ledger: Ledger
    var chunks = 3
    var delayNanos: UInt64 = 2_000_000
    func capabilityReport(for install: ModelInstall) -> BackendCapabilityReport {
        BackendCapabilityReport(backend: kind, runtimeVersion: "mock", ready: true, supportedFeatures: [.directInference, .tokenStreaming])
    }
    func loadRuntime(for install: ModelInstall) async throws -> BackendRuntime {
        await ledger.loaded(install.id)
        return MockRuntime(backend: kind, modelID: install.id, ledger: ledger, chunks: chunks, delayNanos: delayNanos)
    }
    func makeCompatibilityChecker(for install: ModelInstall) -> CompatibilityChecking { Pass() }
    var lifecycleTraits: BackendLifecycleTraits {
        BackendLifecycleTraits(residency: .weightsResident, inProcess: true, prefixReuse: .none, serializesRequestsPerModel: true,
                               contextBoundedAtLoad: kind == .gguf, cancelsDuringPrefill: true, supportsIOS: kind == .gguf)
    }
}
private struct Pass: CompatibilityChecking { func validate(manifest: CacheManifest) throws {} }

private func install(_ id: String, _ backend: BackendKind = .gguf, size: Int64 = 1_000_000, path: String? = nil) -> ModelInstall {
    ModelInstall(id: id, spec: ModelSpec(id: id, displayName: id, backend: backend, source: ModelSource(kind: .localPath, reference: id)),
                 installPath: path ?? "/tmp/\(id)", sizeBytes: size, backendFormat: backend.rawValue)
}

private func runtime(_ ledger: Ledger, installs: [ModelInstall], lifecycle: EshRuntimeLifecycle,
                     chunks: Int = 3, delay: UInt64 = 2_000_000) -> EshRuntime {
    EshRuntime(registry: InferenceBackendRegistry(backends: [
                   .gguf: MockBackend(kind: .gguf, ledger: ledger, chunks: chunks, delayNanos: delay),
                   .mlx: MockBackend(kind: .mlx, ledger: ledger, chunks: chunks, delayNanos: delay),
                   .apple: MockBackend(kind: .apple, ledger: ledger, chunks: chunks, delayNanos: delay)]),
               installProvider: StaticInstallProvider(installs), lifecycle: lifecycle)
}

private func ask(_ id: String, _ text: String = "hi", maxTokens: Int = 32) -> EshGenerationRequest {
    EshGenerationRequest(prompt: text, constraints: .pinned(id), config: GenerationConfig(maxTokens: maxTokens))
}

@Suite struct ManagedLifecycleTests {

    // One-shot (default) — every call loads and releases; nothing outlives the call (the pre-fix facade never unloaded).
    @Test func oneShotReleasesTheRuntimeAfterEveryCall() async throws {
        let ledger = Ledger()
        let rt = runtime(ledger, installs: [install("a")], lifecycle: .oneShot)
        for _ in 0..<5 { _ = try await rt.generate(ask("a")) }
        for try await _ in rt.stream(ask("a")) {}
        #expect(await ledger.loadCount("a") == 6)
        #expect(await ledger.unloadCount("a") == 6)
        let status = await rt.runtimeStatus()
        #expect(status.mode == .oneShot && status.pool == nil)
    }

    @Test func oneShotCancelledStreamStillReleases() async throws {
        let ledger = Ledger()
        let rt = runtime(ledger, installs: [install("a")], lifecycle: .oneShot, chunks: 200, delay: 5_000_000)
        let task = Task { var n = 0; for try await _ in rt.stream(ask("a")) { n += 1; if n == 3 { break } } }
        _ = await task.result
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(await ledger.unloadCount("a") == 1)
    }

    // Managed — one load, reused for every turn, through both generate and stream.
    @Test func managedLoadsOnceAndReusesAcrossThirtyTurns() async throws {
        let ledger = Ledger()
        let rt = runtime(ledger, installs: [install("a")], lifecycle: .managed())
        for i in 0..<30 {
            if i.isMultiple(of: 2) { _ = try await rt.generate(ask("a")) } else { for try await _ in rt.stream(ask("a")) {} }
        }
        #expect(await ledger.loadCount("a") == 1)
        #expect(await ledger.unloadCount("a") == 0)
        let pool = try #require(await rt.runtimeStatus().pool)
        #expect(pool.residents.map(\.modelID) == ["a"])
        #expect(pool.residents.first?.loadCount == 1)
        #expect(pool.residents.first?.state == "warm")
        #expect(pool.residents.first?.measuredMemoryBytes == 123_000_000)   // request metrics reach the pool budget
        #expect(pool.activeRequests == 0)
    }

    @Test func managedStreamReleasesBeforeCompleted() async throws {
        let ledger = Ledger()
        let rt = runtime(ledger, installs: [install("a")], lifecycle: .managed())
        for try await event in rt.stream(ask("a")) {
            if case .completed = event {
                #expect(await rt.runtimeStatus().pool?.activeRequests == 0)
            }
        }
    }

    @Test func managedCancellationReleasesTheSlotAndKeepsTheModelWarm() async throws {
        let ledger = Ledger()
        let rt = runtime(ledger, installs: [install("a")], lifecycle: .managed(.init(maxConcurrentRequests: 1)),
                         chunks: 400, delay: 5_000_000)
        let task = Task { var n = 0; for try await _ in rt.stream(ask("a")) { n += 1; if n == 3 { break } } }
        _ = await task.result
        try await Task.sleep(nanoseconds: 200_000_000)
        let pool = try #require(await rt.runtimeStatus().pool)
        #expect(pool.activeRequests == 0)
        #expect(await ledger.unloadCount("a") == 0)
        // The single concurrency slot is free again: a follow-up completes.
        let r = try await rt.generate(ask("a", "next"))
        #expect(r.text.hasPrefix("[next]"))
    }

    @Test func managedSessionIsolationUnderConcurrency() async throws {
        let ledger = Ledger()
        let rt = runtime(ledger, installs: [install("a")], lifecycle: .managed(.init(maxConcurrentRequests: 2)))
        let texts = try await withThrowingTaskGroup(of: (Int, String).self) { g in
            for i in 0..<8 { g.addTask { (i, try await rt.generate(ask("a", "q\(i)")).text) } }
            var out = [Int: String](); for try await (i, t) in g { out[i] = t }; return out
        }
        for i in 0..<8 { #expect(texts[i]?.hasPrefix("[q\(i)]") == true) }
        #expect(await ledger.peakConcurrency() <= 2)
        #expect(await ledger.loadCount("a") == 1)   // concurrent first requests share one deduplicated load
    }

    @Test func managedSwitchingRespectsResidentLimit() async throws {
        let ledger = Ledger()
        let rt = runtime(ledger, installs: [install("a"), install("b", .mlx)], lifecycle: .managed(.init(maxResidentModels: 1)))
        _ = try await rt.generate(ask("a"))
        _ = try await rt.generate(ask("b"))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await ledger.unloadCount("a") == 1)            // LRU eviction on switch
        #expect(await rt.runtimeStatus().pool?.residents.map(\.modelID) == ["b"])
        _ = try await rt.generate(ask("a"))
        #expect(await ledger.loadCount("a") == 2)
        // With room for both, switching keeps both warm.
        let ledger2 = Ledger()
        let rt2 = runtime(ledger2, installs: [install("a"), install("b", .mlx)], lifecycle: .managed(.init(maxResidentModels: 2)))
        for _ in 0..<3 { _ = try await rt2.generate(ask("a")); _ = try await rt2.generate(ask("b")) }
        #expect(await ledger2.loadCount("a") == 1)
        #expect(await ledger2.loadCount("b") == 1)
    }

    @Test func prewarmLoadsAheadOfTheFirstRequest() async throws {
        let ledger = Ledger()
        let rt = runtime(ledger, installs: [install("a")], lifecycle: .managed())
        try await rt.prewarm(modelID: "a")
        #expect(await ledger.loadCount("a") == 1)
        _ = try await rt.generate(ask("a"))
        #expect(await ledger.loadCount("a") == 1)
        // One-shot: prewarm is a no-op (nothing would stay resident).
        let one = runtime(ledger, installs: [install("z")], lifecycle: .oneShot)
        try await one.prewarm(modelID: "z")
        #expect(await ledger.loadCount("z") == 0)
    }

    @Test func explicitUnloadNeverTouchesAnActiveModel() async throws {
        let ledger = Ledger()
        let rt = runtime(ledger, installs: [install("a")], lifecycle: .managed(), chunks: 100, delay: 5_000_000)
        let long = Task { try await rt.generate(ask("a")) }
        try await Task.sleep(nanoseconds: 60_000_000)
        await #expect(throws: UnloadError.modelActive("a")) { try await rt.unload(modelID: "a") }
        _ = try await long.value
        try await rt.unload(modelID: "a")
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await ledger.unloadCount("a") == 1)
        #expect(await rt.runtimeStatus().pool?.residents.isEmpty == true)
    }

    @Test func shutdownUnloadsEverythingAndRefusesNewWork() async throws {
        let ledger = Ledger()
        let rt = runtime(ledger, installs: [install("a"), install("b", .mlx)], lifecycle: .managed())
        _ = try await rt.generate(ask("a")); _ = try await rt.generate(ask("b"))
        await rt.shutdown()
        #expect(await ledger.unloadCount("a") == 1)   // awaited, not fire-and-forget
        #expect(await ledger.unloadCount("b") == 1)
        let status = await rt.runtimeStatus()
        #expect(status.isShutDown && status.pool?.residents.isEmpty == true)
        await #expect(throws: EshRuntimeError.self) { _ = try await rt.generate(ask("a")) }
        await rt.shutdown()   // idempotent
    }

    @Test func appleFoundationModelsBypassThePool() async throws {
        let ledger = Ledger()
        let rt = runtime(ledger, installs: [], lifecycle: .managed())
        _ = try await rt.generate(EshGenerationRequest(prompt: "hi", constraints: .pinned(AppleProvider.syntheticInstall().id)))
        let status = await rt.runtimeStatus()
        #expect(status.pool == nil || status.pool?.residents.isEmpty == true)
    }

    @Test func unsafeLoadIsRefusedWithATypedErrorAndNoLeakedSlot() async throws {
        let ledger = Ledger()
        // 10 TB of weights: the live load gate must refuse it on any machine.
        let rt = runtime(ledger, installs: [install("huge", size: 10_000_000_000_000), install("a")],
                         lifecycle: .managed(.init(maxConcurrentRequests: 1)))
        await #expect(throws: EshRuntimeError.self) { _ = try await rt.generate(ask("huge")) }
        #expect(await ledger.loadCount("huge") == 0)
        _ = try await rt.generate(ask("a"))   // the concurrency slot was given back
        #expect(await rt.runtimeStatus().pool?.activeRequests == 0)
    }

    @Test func contextGrowthGuardRefusesAnImpossibleContextAndReleases() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = #"{"num_hidden_layers": 32, "num_attention_heads": 32, "num_key_value_heads": 8, "hidden_size": 4096}"#
        try config.write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        let ledger = Ledger()
        let rt = runtime(ledger, installs: [install("m", .mlx, path: dir.path)], lifecycle: .managed(.init(maxConcurrentRequests: 1)))
        await #expect(throws: EshRuntimeError.self) { _ = try await rt.generate(ask("m", maxTokens: 50_000_000)) }
        var streamError: Error?
        do { for try await _ in rt.stream(ask("m", maxTokens: 50_000_000)) {} } catch { streamError = error }
        #expect(streamError is EshRuntimeError)
        #expect(await rt.runtimeStatus().pool?.activeRequests == 0)
        _ = try await rt.generate(ask("m", maxTokens: 64))   // a normal request still runs on the warm model
        #expect(await ledger.loadCount("m") == 1)
    }

    @Test func statusReportsEachBackendsLifecycleTraits() async throws {
        let rt = EshRuntime(registry: InferenceBackendRegistry(backends: [.apple: AppleBackend()]))
        let status = await rt.runtimeStatus()
        let apple = try #require(status.backends[.apple])
        #expect(apple.prefixReuse == .systemManaged && apple.inProcess && apple.supportsIOS)
        #expect(status.mode == .oneShot)
    }

    @Test func textModelReadinessReportsHonestStates() async throws {
        let ledger = Ledger()
        let rt = runtime(ledger, installs: [install("a"), install("huge", size: 10_000_000_000_000)],
                         lifecycle: .managed())
        #expect(await rt.textModelReadiness("a").state == .ready)
        #expect(await rt.textModelReadiness("missing").state == .notInstalled)
        let huge = await rt.textModelReadiness("huge")
        #expect(huge.state == .insufficientMemory && huge.reason != nil && !huge.canRunNow)
        _ = try await rt.generate(ask("a"))
        let resident = await rt.textModelReadiness("a")
        #expect(resident.state == .resident && resident.lifecycle?.residency == .weightsResident)
        #expect(await ledger.loadCount("a") == 1)   // readiness never loads
        // A runtime without the GGUF backend wired says so instead of failing at request time.
        let appleOnly = EshRuntime(registry: InferenceBackendRegistry(backends: [.apple: AppleBackend()]),
                                   installProvider: StaticInstallProvider([install("g")]))
        #expect(await appleOnly.textModelReadiness("g").state == .backendNotWired)
    }
}
