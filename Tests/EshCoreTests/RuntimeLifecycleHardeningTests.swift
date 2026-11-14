import Foundation
import Testing
@testable import EshCore

// Hardening tests for the warm pool + the shared load gate (2026-11 Ghost Infer follow-up).

private final class HardeningRuntime: BackendRuntime, CacheMemoryReporting, @unchecked Sendable {
    let backend: BackendKind = .mlx
    let modelID: String
    private let lock = NSLock()
    private var _cacheBytes: Int64
    private var _unloaded = false
    private var _cacheReleases = 0
    let unloadDelayNanos: UInt64
    let onUnload: (@Sendable () -> Void)?

    init(modelID: String, cacheBytes: Int64 = 0, unloadDelayNanos: UInt64 = 0, onUnload: (@Sendable () -> Void)? = nil) {
        self.modelID = modelID; self._cacheBytes = cacheBytes
        self.unloadDelayNanos = unloadDelayNanos; self.onUnload = onUnload
    }

    var metrics: Metrics { get async { Metrics(memoryBytes: 1_000, residentCacheBytes: residentCacheBytesNow) } }
    var residentCacheBytesNow: Int64 { lock.withLock { _cacheBytes } }
    var unloaded: Bool { lock.withLock { _unloaded } }
    var cacheReleases: Int { lock.withLock { _cacheReleases } }
    func setCache(_ bytes: Int64) { lock.withLock { _cacheBytes = bytes } }

    func residentCacheBytes() async -> Int64 { residentCacheBytesNow }
    func releaseCaches() async { lock.withLock { _cacheBytes = 0; _cacheReleases += 1 } }

    func prepare(session: ChatSession) async throws {}
    func generate(session: ChatSession, config: GenerationConfig) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func exportRuntimeCache() async throws -> CacheSnapshot { throw StoreError.invalidManifest("n/a") }
    func importRuntimeCache(_ snapshot: CacheSnapshot) async throws {}
    func validateCacheCompatibility(_ manifest: CacheManifest) async throws {}
    func unload() async {
        if unloadDelayNanos > 0 { try? await Task.sleep(nanoseconds: unloadDelayNanos) }
        lock.withLock { _unloaded = true }
        onUnload?()
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    func set() { lock.withLock { v = true } }
    var value: Bool { lock.withLock { v } }
}

private func install(_ id: String, gib: Double = 1) -> ModelInstall {
    let spec = ModelSpec(id: id, displayName: id, backend: .mlx, source: ModelSource(kind: .localPath, reference: "local/\(id)"))
    return ModelInstall(id: id, spec: spec, installPath: "/tmp/\(id)", sizeBytes: Int64(gib * 1_073_741_824), backendFormat: "mlx")
}


@Suite struct RuntimeLifecycleHardeningTests {
    @Test func loadWaitsForEvictedModelsToFinishUnloading() async throws {
        // count limit 1: loading B evicts A; A's unload is slow. B's loader must only run after A is gone, so
        // the live memory gate inside the loader measures memory after eviction.
        let aGone = Flag()
        let loaderSawAGone = Flag()
        let mgr = RuntimeLifecycleManager(config: .init(maxResidentModels: 1), loader: { inst in
            if inst.id == "a" {
                return HardeningRuntime(modelID: "a", unloadDelayNanos: 80_000_000, onUnload: { aGone.set() })
            }
            if aGone.value { loaderSawAGone.set() }
            return HardeningRuntime(modelID: inst.id)
        })
        _ = try await mgr.acquire(install: install("a"))
        await mgr.release(modelID: "a")
        _ = try await mgr.acquire(install: install("b"))
        await mgr.release(modelID: "b")
        #expect(loaderSawAGone.value)
    }
}

@Suite struct ResidentCacheAccountingTests {
    private let gib: Int64 = 1_073_741_824

    @Test func reportedCacheBytesCountTowardTheBudget() async throws {
        // budget 10 GB, estimator = size. A (3 GB weights) + 5 GB of resident cache = 8 GB in use.
        let a = HardeningRuntime(modelID: "a", cacheBytes: 5 * gib)
        let mgr = RuntimeLifecycleManager(usableBudgetGB: 10, estimator: { Double($0.sizeBytes) / 1_073_741_824 },
                                          loader: { $0.id == "a" ? a : HardeningRuntime(modelID: $0.id) })
        try await mgr.withRuntime(install: install("a", gib: 3)) { _ in }
        let status = await mgr.status()
        #expect(abs(status.estimatedResidentMemoryGB - 8) < 0.11)
        #expect(status.residentCacheGB == 5)
    }

    @Test func idleCachesAreReleasedBeforeEvictingAWholeModel() async throws {
        // A: 3 GB weights + 5 GB cache. Loading B (4 GB) into a 10 GB budget fits only if A's cache goes;
        // A itself must stay resident.
        let a = HardeningRuntime(modelID: "a", cacheBytes: 5 * gib)
        let mgr = RuntimeLifecycleManager(usableBudgetGB: 10, estimator: { Double($0.sizeBytes) / 1_073_741_824 },
                                          loader: { $0.id == "a" ? a : HardeningRuntime(modelID: $0.id) })
        try await mgr.withRuntime(install: install("a", gib: 3)) { _ in }
        try await mgr.withRuntime(install: install("b", gib: 4)) { _ in }
        #expect(a.cacheReleases == 1)
        #expect(!a.unloaded)
        #expect(Set(await mgr.residentModelIDs()) == ["a", "b"])
    }

    @Test func activeRuntimesKeepTheirCaches() async throws {
        let a = HardeningRuntime(modelID: "a", cacheBytes: 2 * gib)
        let mgr = RuntimeLifecycleManager(loader: { _ in a })
        _ = try await mgr.acquire(install: install("a"))      // active
        await mgr.release(modelID: "a", residentCacheBytes: 2 * gib)
        _ = try await mgr.acquire(install: install("a"))      // active again
        let freed = await mgr.releaseIdleCaches()
        #expect(freed == 0)
        #expect(a.cacheReleases == 0)
        await mgr.release(modelID: "a")
    }

    @Test func memoryWarningReleasesIdleCachesOnly() async throws {
        let a = HardeningRuntime(modelID: "a", cacheBytes: 2 * gib)
        let mgr = RuntimeLifecycleManager(loader: { _ in a })
        try await mgr.withRuntime(install: install("a")) { _ in }
        await mgr.handle(.memoryWarning)
        #expect(a.cacheReleases == 1)
        #expect(!a.unloaded)
        #expect(await mgr.status().residentCacheGB == nil)
    }

    @Test func memoryCriticalAlsoEvictsIdleModelsButNotActiveOnes() async throws {
        let idle = HardeningRuntime(modelID: "idle", cacheBytes: gib)
        let busy = HardeningRuntime(modelID: "busy", cacheBytes: gib)
        let mgr = RuntimeLifecycleManager(loader: { $0.id == "idle" ? idle : busy })
        try await mgr.withRuntime(install: install("idle")) { _ in }
        _ = try await mgr.acquire(install: install("busy"))   // in flight
        await mgr.handle(.memoryCritical)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(idle.unloaded)
        #expect(!busy.unloaded)
        #expect(busy.cacheReleases == 0)
        #expect(await mgr.residentModelIDs() == ["busy"])
        await mgr.release(modelID: "busy")
    }

    @Test func pressureSourceDrivesThePool() async throws {
        struct OneShot: RuntimePressureSource {
            func events() -> AsyncStream<RuntimePressureEvent> {
                AsyncStream { c in c.yield(.memoryWarning); c.finish() }
            }
        }
        let a = HardeningRuntime(modelID: "a", cacheBytes: gib)
        let mgr = RuntimeLifecycleManager(loader: { _ in a })
        try await mgr.withRuntime(install: install("a")) { _ in }
        await mgr.monitorPressure(OneShot()).value
        #expect(a.cacheReleases == 1)
    }
}

@Suite struct RuntimeLifecycleShutdownTests {
    @Test func shutdownAwaitsEveryUnload() async throws {
        let slow = HardeningRuntime(modelID: "slow", unloadDelayNanos: 120_000_000)
        let fast = HardeningRuntime(modelID: "fast")
        let mgr = RuntimeLifecycleManager(loader: { $0.id == "slow" ? slow : fast })
        try await mgr.withRuntime(install: install("slow")) { _ in }
        try await mgr.withRuntime(install: install("fast")) { _ in }
        await mgr.shutdown()
        #expect(slow.unloaded)          // returned only after the slow teardown finished
        #expect(fast.unloaded)
        #expect(await mgr.residentModelIDs().isEmpty)
    }
}
