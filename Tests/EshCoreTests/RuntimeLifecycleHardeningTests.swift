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
    let onReleaseCaches: (@Sendable () -> Void)?

    init(modelID: String, cacheBytes: Int64 = 0, unloadDelayNanos: UInt64 = 0, onUnload: (@Sendable () -> Void)? = nil,
         onReleaseCaches: (@Sendable () -> Void)? = nil) {
        self.modelID = modelID; self._cacheBytes = cacheBytes
        self.unloadDelayNanos = unloadDelayNanos; self.onUnload = onUnload; self.onReleaseCaches = onReleaseCaches
    }

    var metrics: Metrics { get async { Metrics(memoryBytes: 1_000, residentCacheBytes: residentCacheBytesNow) } }
    var residentCacheBytesNow: Int64 { lock.withLock { _cacheBytes } }
    var unloaded: Bool { lock.withLock { _unloaded } }
    var cacheReleases: Int { lock.withLock { _cacheReleases } }
    func setCache(_ bytes: Int64) { lock.withLock { _cacheBytes = bytes } }

    func residentCacheBytes() async -> Int64 { residentCacheBytesNow }
    func releaseCaches() async { lock.withLock { _cacheBytes = 0; _cacheReleases += 1 }; onReleaseCaches?() }

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

/// A growth gate that "fits" once enough memory was reclaimed (caches released or models unloaded).
private final class ReclaimLedger: @unchecked Sendable {
    private let lock = NSLock(); private var freedGB = 0.0
    func free(_ gb: Double) { lock.withLock { freedGB += gb } }
    var freed: Double { lock.withLock { freedGB } }
}

@Suite struct ContextGrowthGuardTests {
    private let gib: Int64 = 1_073_741_824

    private func gate(availableGB: Double, ledger: ReclaimLedger) -> RuntimeLifecycleManager.GrowthGate {
        { needGB in
            let avail = availableGB + ledger.freed
            return needGB <= avail ? .fits : .gated(reason: String(format: "%.1f GB available", avail), requiredGB: needGB, availableGB: avail)
        }
    }

    @Test func fitsWithoutReclaiming() async throws {
        let ledger = ReclaimLedger()
        let a = HardeningRuntime(modelID: "a", cacheBytes: 2 * gib)
        let mgr = RuntimeLifecycleManager(loader: { _ in a }, growthGate: gate(availableGB: 8, ledger: ledger))
        try await mgr.withRuntime(install: install("a")) { _ in }
        try await mgr.ensureHeadroom(forAdditionalBytes: 4 * gib, modelID: "other")
        #expect(a.cacheReleases == 0)
        #expect(!a.unloaded)
    }

    @Test func releasesIdleCachesBeforeEvictingModels() async throws {
        let ledger = ReclaimLedger()
        let idle = HardeningRuntime(modelID: "idle", cacheBytes: 3 * gib, onReleaseCaches: { ledger.free(3) })
        let mgr = RuntimeLifecycleManager(loader: { $0.id == "idle" ? idle : HardeningRuntime(modelID: $0.id) },
                                          growthGate: gate(availableGB: 2, ledger: ledger))
        try await mgr.withRuntime(install: install("idle")) { _ in }
        _ = try await mgr.acquire(install: install("busy"))          // the requesting model, active
        try await mgr.ensureHeadroom(forAdditionalBytes: 4 * gib, modelID: "busy")
        #expect(idle.cacheReleases == 1)
        #expect(!idle.unloaded)                                       // caches were enough; model kept
        await mgr.release(modelID: "busy")
    }

    @Test func evictsIdleModelsWhenCachesAreNotEnough() async throws {
        let ledger = ReclaimLedger()
        let idle = HardeningRuntime(modelID: "idle", onUnload: { ledger.free(10) })
        let busy = HardeningRuntime(modelID: "busy")
        let mgr = RuntimeLifecycleManager(loader: { $0.id == "idle" ? idle : busy },
                                          growthGate: gate(availableGB: 2, ledger: ledger))
        try await mgr.withRuntime(install: install("idle")) { _ in }
        _ = try await mgr.acquire(install: install("busy"))
        try await mgr.ensureHeadroom(forAdditionalBytes: 6 * gib, modelID: "busy")
        #expect(idle.unloaded)
        #expect(!busy.unloaded)
        #expect(await mgr.residentModelIDs() == ["busy"])
        await mgr.release(modelID: "busy")
    }

    @Test func refusesWithAnActionableErrorAndLeavesActiveWorkAlone() async throws {
        let ledger = ReclaimLedger()
        let busy = HardeningRuntime(modelID: "busy", cacheBytes: 2 * gib)
        let mgr = RuntimeLifecycleManager(loader: { _ in busy }, growthGate: gate(availableGB: 1, ledger: ledger))
        _ = try await mgr.acquire(install: install("busy"))
        await #expect(throws: RuntimeLifecycleError.self) {
            try await mgr.ensureHeadroom(forAdditionalBytes: 20 * gib, modelID: "busy")
        }
        do { try await mgr.ensureHeadroom(forAdditionalBytes: 20 * gib, modelID: "busy") }
        catch { #expect(error.localizedDescription.contains("Shorten the conversation")) }
        #expect(!busy.unloaded)
        #expect(busy.cacheReleases == 0)                              // an active request's cache is never released
        await mgr.release(modelID: "busy")
    }
}

@Suite struct KVCacheEstimatorTests {
    @Test func llamaStyleConfig() {
        // Llama-3-8B: 32 layers, 8 kv heads, 4096/32 = 128 head dim -> 128 KiB per token
        let c: [String: Any] = ["num_hidden_layers": 32, "num_attention_heads": 32, "num_key_value_heads": 8, "hidden_size": 4096]
        #expect(KVCacheEstimator.bytesPerToken(config: c) == 131_072)
    }

    @Test func explicitHeadDimAndNestedTextConfig() {
        let inner: [String: Any] = ["num_hidden_layers": 28, "num_attention_heads": 16, "num_key_value_heads": 8, "head_dim": 128]
        let c: [String: Any] = ["text_config": inner]
        let got = KVCacheEstimator.bytesPerToken(config: c)
        #expect(got == Int64(114_688))   // 28 layers x 8 kv heads x 128 dim x 2 tensors x 2 bytes
    }

    @Test func unknownConfigIsNil() {
        #expect(KVCacheEstimator.bytesPerToken(config: ["vocab_size": 10]) == nil)
    }

    @Test func growthCountsPromptAndMaxTokens() {
        let g = KVCacheEstimator.growthBytes(bytesPerToken: 1000, promptCharacters: 3000, messages: 2, maxTokens: 500)
        #expect(g == Int64(1000 + 32 + 64 + 500) * 1000)
    }

    @Test func growthModePreflightHasNoSmallModelFloor() {
        let host = HostResources(totalMemoryGB: 32, availableMemoryGB: 1, systemVolumeFreeGB: 1, assetsVolumeFreeGB: 100,
                                 assetsVolumeAvailable: true, residentHeavyMemoryGB: 0, memoryCritical: false)
        #expect(MemorySafetyPreflight.evaluate(requiredPeakGB: 3, host: host).fits)                                  // model floor
        #expect(!MemorySafetyPreflight.evaluate(requiredPeakGB: 3, host: host, applySmallModelFloor: false).fits)    // growth
    }
}

@Suite struct PrefixCacheDiagnosticsTests {
    @Test func poolStatusReportsTheEffectiveCacheModeAndResidentCache() async throws {
        let r = HardeningRuntime(modelID: "m")
        let mgr = RuntimeLifecycleManager(loader: { _ in r })
        _ = try await mgr.acquire(install: install("m"))
        await mgr.release(modelID: "m", residentCacheBytes: 2048, prefixCacheMode: "live")
        let info = try #require(await mgr.status().residents.first)
        #expect(info.prefixCacheMode == "live")
        #expect(info.residentCacheBytes == 2048)
    }

    @Test func metricsDecodeTheBridgeDiagnostics() throws {
        let json = #"{"prefixCacheMode":"tokens","prefixCacheFallback":"session cache exceeds the live-cache budget","residentCacheBytes":0}"#
        let m = try JSONDecoder().decode(Metrics.self, from: Data(json.utf8))
        #expect(m.prefixCacheMode == "tokens")
        #expect(m.prefixCacheFallback?.contains("budget") == true)
    }
}
