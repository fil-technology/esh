import Foundation
import Testing
@testable import EshCore

// Minimal BackendRuntime stub for lifecycle tests.
private final class MockRuntime: BackendRuntime, @unchecked Sendable {
    let backend: BackendKind
    let modelID: String
    var metrics: Metrics { get async { Metrics(memoryBytes: 1_000) } }
    init(backend: BackendKind = .mlx, modelID: String) { self.backend = backend; self.modelID = modelID }
    func prepare(session: ChatSession) async throws {}
    func generate(session: ChatSession, config: GenerationConfig) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func exportRuntimeCache() async throws -> CacheSnapshot { throw StoreError.invalidManifest("n/a") }
    func importRuntimeCache(_ snapshot: CacheSnapshot) async throws {}
    func validateCacheCompatibility(_ manifest: CacheManifest) async throws {}
    func unload() async {}
}

private actor Counter { var n = 0; func inc() { n += 1 }; func value() -> Int { n } }

@Suite
struct RuntimeLifecycleManagerTests {
    private func install(_ id: String, gib: Double = 1) -> ModelInstall {
        let spec = ModelSpec(id: id, displayName: id, backend: .mlx, source: ModelSource(kind: .localPath, reference: "local/\(id)"))
        return ModelInstall(id: id, spec: spec, installPath: "/tmp/\(id)", sizeBytes: Int64(gib * 1_073_741_824), backendFormat: "mlx")
    }

    @Test
    func deduplicatesConcurrentLoadsOfSameModel() async throws {
        let counter = Counter()
        let mgr = RuntimeLifecycleManager(loader: { inst in
            await counter.inc()
            try? await Task.sleep(nanoseconds: 15_000_000)
            return MockRuntime(modelID: inst.id)
        })
        let a = install("m")
        async let r1: BackendRuntime = mgr.acquire(install: a)
        async let r2: BackendRuntime = mgr.acquire(install: a)
        _ = try await (r1, r2)
        await mgr.release(modelID: "m"); await mgr.release(modelID: "m")
        #expect(await counter.value() == 1)   // loaded once despite two concurrent acquires
    }

    @Test
    func cancellationOfAWaitingRequestThrows() async throws {
        // Concurrency limit 1: first acquire holds the slot; second waits and is cancelled.
        let mgr = RuntimeLifecycleManager(config: .init(maxConcurrentRequests: 1), loader: { MockRuntime(modelID: $0.id) })
        _ = try await mgr.acquire(install: install("a"))   // holds the only slot
        let waiting = Task { try await mgr.acquire(install: install("b")) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        waiting.cancel()
        await #expect(throws: Error.self) { _ = try await waiting.value }
        await mgr.release(modelID: "a")
    }

    @Test
    func idleEvictionKeepsFreshModels() async throws {
        let mgr = RuntimeLifecycleManager(config: .init(idleTimeoutSeconds: 60), loader: { MockRuntime(modelID: $0.id) },
                                          clock: { Date(timeIntervalSince1970: 1_000_000) })
        _ = try await mgr.acquire(install: install("m"))
        await mgr.release(modelID: "m")
        // Nothing evicted immediately (lastUsed == now, fixed clock).
        #expect(await mgr.evictIdle().isEmpty)
    }

    @Test
    func idleEvictionWithAdvancingClockEvicts() async throws {
        let store = ClockBox()
        let mgr = RuntimeLifecycleManager(config: .init(idleTimeoutSeconds: 60), loader: { MockRuntime(modelID: $0.id) }, clock: { store.now })
        _ = try await mgr.acquire(install: install("m"))
        await mgr.release(modelID: "m")
        store.now = store.now.addingTimeInterval(120)   // advance past idle timeout
        let evicted = await mgr.evictIdle()
        #expect(evicted == ["m"])
    }

    @Test
    func overBudgetIsRefusedWhenNothingEvictable() async throws {
        // 4 GB usable, TTS reserve 0; a 10 GB model cannot fit and nothing else is resident.
        let mgr = RuntimeLifecycleManager(config: .init(memorySafetyReserveGB: 0), usableBudgetGB: 4,
                                          estimator: { _ in 10 }, loader: { MockRuntime(modelID: $0.id) })
        await #expect(throws: RuntimeLifecycleError.self) {
            _ = try await mgr.acquire(install: install("big", gib: 6))
        }
    }

    @Test
    func evictsIdleToFitNewModelWithinBudget() async throws {
        // 12 GB usable; two 5 GB models. Loading a third 5 GB should evict the idle LRU one.
        let mgr = RuntimeLifecycleManager(config: .init(maxResidentModels: 0), usableBudgetGB: 12,
                                          estimator: { _ in 5 }, loader: { MockRuntime(modelID: $0.id) })
        _ = try await mgr.acquire(install: install("a")); await mgr.release(modelID: "a")
        _ = try await mgr.acquire(install: install("b")); await mgr.release(modelID: "b")
        _ = try await mgr.acquire(install: install("c")); await mgr.release(modelID: "c")
        let ids = Set(await mgr.residentModelIDs())
        #expect(ids.count == 2)             // one evicted to fit the third
        #expect(ids.contains("c"))          // newest stays
    }

    @Test
    func ttsReserveReducesBudget() async throws {
        // 10 GB usable, 6 GB TTS reserve -> only 4 GB left; a 5 GB model must be refused.
        let mgr = RuntimeLifecycleManager(config: .init(memorySafetyReserveGB: 0, ttsReserveGB: 6), usableBudgetGB: 10,
                                          estimator: { _ in 5 }, loader: { MockRuntime(modelID: $0.id) })
        await #expect(throws: RuntimeLifecycleError.self) {
            _ = try await mgr.acquire(install: install("m"))
        }
    }

    @Test
    func failedLoadRecoversOnRetry() async throws {
        let attempts = Counter()
        let mgr = RuntimeLifecycleManager(loader: { inst in
            await attempts.inc()
            if await attempts.value() == 1 { throw StoreError.invalidManifest("boom") }
            return MockRuntime(modelID: inst.id)
        })
        await #expect(throws: RuntimeLifecycleError.self) { _ = try await mgr.acquire(install: install("m")) }
        await mgr.release(modelID: "m")   // free the slot taken by the failed acquire's admit
        let r = try await mgr.acquire(install: install("m"))
        #expect(r.modelID == "m")
        await mgr.release(modelID: "m")
    }

    @Test
    func unloadAndReloadIncrementsLoadCount() async throws {
        let mgr = RuntimeLifecycleManager(loader: { MockRuntime(modelID: $0.id) })
        _ = try await mgr.acquire(install: install("m")); await mgr.release(modelID: "m")
        #expect(await mgr.unload(modelID: "m"))
        _ = try await mgr.acquire(install: install("m")); await mgr.release(modelID: "m")
        let status = await mgr.status()
        #expect(status.residents.first { $0.modelID == "m" }?.loadCount == 1)  // reloaded fresh
    }

    @Test
    func residencyIsTruthfulHandleCachedByDefault() async throws {
        // Default residency is handle-cached: the pool must NOT claim true weight residency for the
        // current subprocess-per-call MLX/llama.cpp backends.
        let mgr = RuntimeLifecycleManager(loader: { MockRuntime(modelID: $0.id) })
        _ = try await mgr.acquire(install: install("m")); await mgr.release(modelID: "m")
        let status = await mgr.status()
        #expect(status.residents.first?.residency == RuntimeResidency.handleCached.rawValue)
    }

    @Test
    func statusReportsResidentsAndBudget() async throws {
        let mgr = RuntimeLifecycleManager(usableBudgetGB: 16, estimator: { _ in 4 }, loader: { MockRuntime(modelID: $0.id) })
        _ = try await mgr.acquire(install: install("m")); await mgr.release(modelID: "m")
        let status = await mgr.status()
        #expect(status.residentCount == 1)
        #expect(status.usableBudgetGB == 16)
        #expect(status.estimatedResidentMemoryGB == 4)
    }
}

/// Simple mutable clock box for injecting time in tests (single-threaded test use).
final class ClockBox: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_000_000)
}
