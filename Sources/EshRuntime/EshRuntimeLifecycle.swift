import Foundation
import EshCore

// Managed SDK inference: the public `EshRuntime` drives the SAME managed infrastructure as `esh serve` — the
// `RuntimeLifecycleManager` warm pool (load dedup, LRU/idle/budget eviction, admission + concurrency limits,
// memory-pressure response, awaited shutdown), the live load gate (`loadRuntimeGuarded` → `ModelLoadSafetyGate` →
// `MemorySafetyPreflight`), the shared KV-growth guard (`ContextGrowthGuard` → `ensureHeadroom` + `KVCacheEstimator`)
// and the runtime's `CacheMemoryReporting` / metrics. Nothing here re-implements scheduling, memory or cache policy;
// the facade only owns one pool per `EshRuntime` and routes requests through it.

/// How an `EshRuntime` owns the model runtimes it loads for text generation.
public enum EshRuntimeLifecycle: Sendable {
    /// Load the model for each request and release it when the request ends (the default, unchanged API). Nothing
    /// stays resident between calls, so every call pays the model load. Right for occasional calls and CLIs.
    case oneShot
    /// Keep models resident in esh's warm pool and reuse them across requests, with esh owning load, reuse,
    /// eviction, concurrency, memory-pressure response, context-growth protection and shutdown. Right for chat apps
    /// and agents. Call `EshRuntime.shutdown()` when the host is done (app teardown) to release every model.
    case managed(EshManagedLifecycleConfiguration = .init())
}

/// Tuning for `EshRuntimeLifecycle.managed`. Defaults are safe for a 16–32 GB Mac and an iPhone; every limit is
/// still enforced by esh's live memory gates, so raising one never bypasses memory safety.
public struct EshManagedLifecycleConfiguration: Sendable, Equatable {
    /// Models kept resident at once (LRU beyond this). 0 = bounded by memory only.
    public var maxResidentModels: Int
    /// Generation requests in flight across all models; further requests wait (interactive before background).
    public var maxConcurrentRequests: Int
    /// A warm model unused for this long is unloaded by the idle sweep.
    public var idleTimeoutSeconds: Double
    /// Memory the pool may plan for. `nil` = physical memory minus `memorySafetyReserveGB`.
    public var memoryBudgetGB: Double?
    /// Memory left for the OS and other apps when the budget is derived from physical memory.
    public var memorySafetyReserveGB: Double
    /// Release idle caches on a memory warning and evict idle models on critical pressure (the system's
    /// memory-pressure events on macOS and iOS). Active requests are never interrupted.
    public var respondsToSystemMemoryPressure: Bool

    public init(maxResidentModels: Int = 2, maxConcurrentRequests: Int = 2, idleTimeoutSeconds: Double = 300,
                memoryBudgetGB: Double? = nil, memorySafetyReserveGB: Double = 3,
                respondsToSystemMemoryPressure: Bool = true) {
        self.maxResidentModels = maxResidentModels
        self.maxConcurrentRequests = maxConcurrentRequests
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.memoryBudgetGB = memoryBudgetGB
        self.memorySafetyReserveGB = memorySafetyReserveGB
        self.respondsToSystemMemoryPressure = respondsToSystemMemoryPressure
    }
}

/// The text-runtime state of an `EshRuntime`: its lifecycle mode and, when managed, the pool's live status
/// (residents with state/residency/estimated + measured memory/load count/active requests/prefix-cache mode and
/// resident cache bytes, plus the pool's budget and limits) — the same `RuntimePoolStatus` `esh serve` reports at
/// `GET /v1/runtime`.
public struct EshRuntimeStatus: Sendable {
    public enum Mode: String, Sendable { case oneShot = "one-shot", managed }
    public var mode: Mode
    /// True after `shutdown()`; a shut-down managed runtime refuses new text requests.
    public var isShutDown: Bool
    /// The pool's status (managed mode, after the first request or `prewarm`); nil otherwise.
    public var pool: RuntimePoolStatus?
    /// Per wired backend: how its runtimes behave (residency, in-process, prefix reuse, bounds, platform).
    public var backends: [BackendKind: BackendLifecycleTraits]
}

extension EshRuntime {
    /// A request's hold on a runtime. One-shot leases own the runtime and unload it at the end; pooled leases are
    /// released back to the pool (with the request's measured metrics) and stay warm.
    struct Lease: Sendable {
        let runtime: any BackendRuntime
        let modelID: String
        let pooled: Bool
    }
}

public extension EshRuntime {
    /// The lifecycle this runtime was built with.
    var lifecycleMode: EshRuntimeStatus.Mode {
        if case .managed = lifecycle { return .managed }
        return .oneShot
    }

    /// Text-runtime status: lifecycle mode, the managed pool's residents and budget, and each backend's traits.
    func runtimeStatus() async -> EshRuntimeStatus {
        var traits: [BackendKind: BackendLifecycleTraits] = [:]
        for kind in BackendKind.allCases { if let b = registry.resolve(kind) { traits[kind] = b.lifecycleTraits } }
        return EshRuntimeStatus(mode: lifecycleMode, isShutDown: isShutDown, pool: await pool?.status(),
                                backends: traits)
    }

    /// Load a model into the managed pool ahead of the first request (e.g. when a chat screen opens), through the
    /// same memory-safety gate as a request. A no-op for one-shot runtimes and for Apple Foundation Models (system
    /// managed). Throws the same typed errors as `generate` for an unknown, unready or unsafe model.
    func prewarm(modelID: String) async throws {
        let plan = try plan(for: EshGenerationRequest(prompt: "", constraints: .pinned(modelID)))
        guard plan.selection.backend != .apple, let pool = try managedPool() else { return }
        do { try await pool.prewarm(install: plan.install) } catch { throw mapLoadError(error, modelID: modelID) }
    }

    /// Release every model this runtime holds and stop its background work (pressure monitor, idle sweep), waiting
    /// until each runtime has actually unloaded (persistent workers stopped, native contexts freed). Also releases
    /// idle capability-provider runtimes. Idempotent. After shutdown a managed runtime refuses new text requests;
    /// build a new `EshRuntime` to start again. One-shot runtimes hold nothing between calls, so this only releases
    /// providers.
    func shutdown() async {
        if case .managed = lifecycle { isShutDown = true }
        for task in poolTasks { task.cancel() }
        poolTasks.removeAll()
        if let pool { await pool.shutdown() }
        await unloadIdleRuntimes()
    }
}

extension EshRuntime {
    /// The managed pool, created on first use (so a runtime that never generates starts no monitors). nil for
    /// one-shot runtimes. Throws when the runtime was shut down.
    func managedPool() throws -> RuntimeLifecycleManager? {
        guard case let .managed(config) = lifecycle else { return nil }
        guard !isShutDown else {
            throw EshRuntimeError.noAvailableBackend(reason: "this EshRuntime was shut down; create a new one to run more requests.")
        }
        if let pool { return pool }
        let registry = self.registry
        let root = persistenceRootRef()
        let totalGB = Double(deviceProfileProvider.currentProfile().physicalMemoryBytes) / 1_073_741_824
        let budget = config.memoryBudgetGB ?? (totalGB > 0 ? max(1, totalGB - config.memorySafetyReserveGB) : nil)
        let manager = RuntimeLifecycleManager(
            config: RuntimeLifecycleConfig(maxResidentModels: config.maxResidentModels,
                                           idleTimeoutSeconds: config.idleTimeoutSeconds,
                                           memorySafetyReserveGB: config.memorySafetyReserveGB,
                                           maxConcurrentRequests: max(1, config.maxConcurrentRequests)),
            usableBudgetGB: budget,
            // Same planning estimate `esh serve` uses (weights on disk × 1.3 for KV/compute); the live load gate and
            // measured metrics correct it at runtime.
            estimator: { install in max(0.2, Double(install.sizeBytes) / 1_073_741_824 * 1.3) },
            loader: { install in
                guard let backend = registry.resolve(install.spec.backend) else {
                    throw EshRuntimeError.backendUnavailable(install.spec.backend, reason: "not wired on this platform.")
                }
                return try await backend.loadRuntimeGuarded(for: install, root: root)
            },
            residencyProbe: { install in registry.resolve(install.spec.backend)?.lifecycleTraits.residency ?? .handleCached }
        )
        if config.respondsToSystemMemoryPressure { poolTasks.append(manager.monitorPressure()) }
        // Idle sweep: the pool marks + evicts models unused past the idle timeout when asked; ask periodically.
        let interval = max(5, min(60, config.idleTimeoutSeconds / 2))
        poolTasks.append(Task { [weak manager] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let manager else { return }
                await manager.evictIdle()
            }
        })
        pool = manager
        return manager
    }

    /// Acquire a runtime for a planned request: from the managed pool (reused, gated, admitted under the concurrency
    /// limit), or a fresh one-shot load. Apple Foundation Models always run one-shot (the system owns the model).
    func lease(_ plan: Plan) async throws -> Lease {
        if plan.selection.backend != .apple, let pool = try managedPool() {
            do {
                let runtime = try await pool.acquire(install: plan.install)
                return Lease(runtime: runtime, modelID: plan.install.id, pooled: true)
            } catch { throw mapLoadError(error, modelID: plan.install.id) }
        }
        return Lease(runtime: try await loadRuntime(plan), modelID: plan.install.id, pooled: false)
    }

    /// End a lease exactly once: release to the pool with the request's measured memory + resident cache (so the pool
    /// budgets real numbers), or unload a one-shot runtime so nothing outlives the call (native contexts freed, MLX
    /// state files + KV sidecars removed, workers stopped).
    func endLease(_ lease: Lease, metrics: Metrics?) async {
        if lease.pooled, let pool {
            await pool.release(modelID: lease.modelID, measuredMemoryBytes: metrics?.memoryBytes,
                               residentCacheBytes: metrics?.residentCacheBytes, prefixCacheMode: metrics?.prefixCacheMode)
        } else if !lease.pooled {
            await lease.runtime.unload()
        }
    }

    /// The shared KV-growth guard, before generating (MLX only; GGUF/Apple are bounded at load).
    func guardContextGrowth(_ plan: Plan, lease: Lease, messages: [Message], maxTokens: Int) async throws {
        do {
            try await ContextGrowthGuard.check(
                install: plan.install, promptCharacters: messages.reduce(0) { $0 + $1.text.count },
                messageCount: messages.count, maxTokens: maxTokens, pool: lease.pooled ? pool : nil,
                weightsNotYetLoaded: !lease.pooled && lease.runtime.prepareBeforeGenerateIsRedundant)
        } catch { throw mapLoadError(error, modelID: plan.install.id) }
    }

    /// Typed mapping for pool/gate failures so hosts branch on `EshRuntimeError`, never on pool internals.
    func mapLoadError(_ error: Error, modelID: String) -> Error {
        switch error {
        case is CancellationError: return CancellationError()
        case let e as EshRuntimeError: return e
        case let refused as ModelLoadRefused: return EshRuntimeError.insufficientMemory(modelID: modelID, reason: refused.reason)
        case let e as RuntimeLifecycleError:
            if case .cancelled = e { return CancellationError() }
            if case .insufficientMemoryForContext = e {
                return EshRuntimeError.insufficientMemory(modelID: modelID, reason: Self.reason(from: e))
            }
            return EshRuntimeError.modelLoadFailed(modelID: modelID, reason: Self.reason(from: e))
        default: return EshRuntimeError.modelLoadFailed(modelID: modelID, reason: Self.reason(from: error))
        }
    }
}

/// Whether one text model can run through this `EshRuntime` right now, and why not — so a host (Studio's model
/// picker) shows an honest state without probing internals or attempting a load. Built from the same checks a
/// request goes through (install store, wired backend, backend readiness, platform, live load-safety gate).
public struct EshTextModelReadiness: Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        /// Loaded and warm in this runtime's managed pool.
        case resident
        /// Installed, backend wired and ready, and fits in memory now.
        case ready
        /// Not in this runtime's install store.
        case notInstalled = "not-installed"
        /// The model's backend cannot run on this platform at all (e.g. MLX on iOS).
        case unsupportedOnPlatform = "unsupported-on-platform"
        /// The backend exists on this platform but this runtime was not built with it.
        case backendNotWired = "backend-not-wired"
        /// The backend reports the model not ready (e.g. weights missing, OS feature off).
        case notReady = "not-ready"
        /// The live memory gate would refuse the load right now.
        case insufficientMemory = "insufficient-memory"
    }
    public var modelID: String
    public var backend: BackendKind?
    public var state: State
    /// Human-readable reason for any state other than `ready`/`resident`.
    public var reason: String?
    /// How the backend that would run it behaves (nil when no backend is wired for it).
    public var lifecycle: BackendLifecycleTraits?
    public var canRunNow: Bool { state == .ready || state == .resident }
}

public extension EshRuntime {
    /// Readiness of one text model on this runtime (see `EshTextModelReadiness`). Does not load anything.
    func textModelReadiness(_ modelID: String) async -> EshTextModelReadiness {
        var isIOS = false
        #if os(iOS) || os(visionOS) || os(tvOS) || os(watchOS)
        isIOS = true
        #endif
        let install: ModelInstall
        if AppleProvider.isAppleModelID(modelID) {
            install = AppleProvider.syntheticInstall()
        } else if let found = installProviderRef().installs().first(where: { $0.id == modelID }) {
            install = found
        } else {
            return EshTextModelReadiness(modelID: modelID, backend: nil, state: .notInstalled,
                                         reason: "not installed in this runtime's model store.", lifecycle: nil)
        }
        let kind = install.spec.backend
        guard let backend = registry.resolve(kind) else {
            let unsupported = isIOS && kind == .mlx
            return EshTextModelReadiness(
                modelID: modelID, backend: kind, state: unsupported ? .unsupportedOnPlatform : .backendNotWired,
                reason: unsupported ? "MLX text models need macOS (Python worker); use a GGUF build of the model on iOS."
                                    : "this EshRuntime was not built with the \(kind.rawValue) backend.",
                lifecycle: nil)
        }
        let traits = backend.lifecycleTraits
        if isIOS, !traits.supportsIOS, traits != .unspecified {
            return EshTextModelReadiness(modelID: modelID, backend: kind, state: .unsupportedOnPlatform,
                                         reason: "the \(kind.rawValue) backend does not run on iOS.", lifecycle: traits)
        }
        let report = backend.capabilityReport(for: install)
        guard report.ready else {
            return EshTextModelReadiness(modelID: modelID, backend: kind, state: .notReady,
                                         reason: report.warnings.first ?? report.unavailableFeatures.first?.reason,
                                         lifecycle: traits)
        }
        if let pool, await pool.residentModelIDs().contains(modelID) {
            return EshTextModelReadiness(modelID: modelID, backend: kind, state: .resident, reason: nil, lifecycle: traits)
        }
        do { try ModelLoadSafetyGate.check(install, root: persistenceRootRef()) } catch let refused as ModelLoadRefused {
            return EshTextModelReadiness(modelID: modelID, backend: kind, state: .insufficientMemory,
                                         reason: refused.reason, lifecycle: traits)
        } catch {
            return EshTextModelReadiness(modelID: modelID, backend: kind, state: .notReady,
                                         reason: Self.reason(from: error), lifecycle: traits)
        }
        return EshTextModelReadiness(modelID: modelID, backend: kind, state: .ready, reason: nil, lifecycle: traits)
    }
}
