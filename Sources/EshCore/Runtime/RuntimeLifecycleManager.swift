import Foundation

/// The warm-pool / runtime lifecycle manager (M7). A backend-agnostic layer ABOVE MLX / llama.cpp /
/// Apple that keeps model runtimes resident and reused, tracks their state and (estimated + measured)
/// memory cost, deduplicates concurrent loads, evicts idle/over-budget models, bounds concurrency
/// with interactive-over-background priority, supports cancellation, and exposes pool status to
/// doctor/status and the Adaptive Scheduler. Backends only provide load/unload hooks underneath.
public actor RuntimeLifecycleManager {
    public typealias Loader = @Sendable (ModelInstall) async throws -> BackendRuntime

    private final class Resident {
        let install: ModelInstall
        var runtime: BackendRuntime?
        var state: ModelRuntimeState
        var estimatedGB: Double?
        var measuredBytes: Int64?
        var activeRequests: Int = 0
        var loadCount: Int = 0
        var lastUsed: Date
        init(install: ModelInstall, estimatedGB: Double?, now: Date) {
            self.install = install
            self.runtime = nil
            self.state = .unloaded
            self.estimatedGB = estimatedGB
            self.lastUsed = now
        }
    }

    private struct Waiter {
        let id: UUID
        let priority: RequestPriority
        let continuation: CheckedContinuation<Void, Error>
    }

    private var config: RuntimeLifecycleConfig
    private let usableBudgetGB: Double?
    private let estimator: @Sendable (ModelInstall) -> Double?
    private let loader: Loader
    private let clock: @Sendable () -> Date
    /// Truthful residency per model. Defaults to `.handleCached`: today's MLX/llama.cpp backends
    /// reload weights per generate (subprocess-per-call), so a cached handle is NOT true weight
    /// residency. A future persistent backend declares `.weightsResident`.
    private let residencyProbe: @Sendable (ModelInstall) -> RuntimeResidency

    private var residents: [String: Resident] = [:]
    private var loadingTasks: [String: Task<BackendRuntime, Error>] = [:]
    private var activeCount = 0
    private var waiters: [Waiter] = []

    // M12: a non-LLM memory consumer (the persistent speech/STT runtime) shares this pool's memory
    // budget without being a full BackendRuntime. `externalReservationGB` is the speech runtime's live
    // resident footprint (0 when it isn't loaded); it's reserved out of the budget so an LLM never
    // over-allocates on top of resident speech. `externalReclaim` lets the pool drop speech to free
    // that memory when an LLM otherwise wouldn't fit. Both are pushed in by the speech manager via
    // `setExternalReservation`.
    private var externalReservationGB: Double = 0
    private var externalReclaim: (@Sendable () async -> Void)?

    public init(
        config: RuntimeLifecycleConfig = .init(),
        usableBudgetGB: Double? = nil,
        estimator: @escaping @Sendable (ModelInstall) -> Double? = { _ in nil },
        loader: @escaping Loader,
        residencyProbe: @escaping @Sendable (ModelInstall) -> RuntimeResidency = { _ in .handleCached },
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.usableBudgetGB = usableBudgetGB
        self.estimator = estimator
        self.loader = loader
        self.residencyProbe = residencyProbe
        self.clock = clock
    }

    // MARK: - Acquire / release

    /// Acquire a warm runtime for a request, loading it (deduplicated) if needed, evicting idle
    /// models to stay within the memory budget, and admitting under the concurrency limit with the
    /// given priority. Marks the model `active`. Call `release` when the request finishes.
    public func acquire(install: ModelInstall, priority: RequestPriority = .interactive) async throws -> BackendRuntime {
        try Task.checkCancellation()
        try await admit(priority: priority)
        do {
            let runtime = try await ensureResident(install: install)
            let resident = residents[install.id]!
            resident.activeRequests += 1
            resident.state = .active
            resident.lastUsed = clock()
            return runtime
        } catch {
            releaseSlot()   // give the concurrency slot back on failure
            throw error
        }
    }

    /// Release a request's hold on a model. Records measured memory (from the generation Metrics),
    /// marks the model warm, and admits the next waiter.
    public func release(modelID: String, measuredMemoryBytes: Int64? = nil) {
        if let resident = residents[modelID] {
            resident.activeRequests = max(0, resident.activeRequests - 1)
            if let measuredMemoryBytes { resident.measuredBytes = measuredMemoryBytes }
            resident.lastUsed = clock()
            if resident.activeRequests == 0 { resident.state = .warm }
        }
        releaseSlot()
    }

    /// Convenience: acquire, run `body(runtime)`, and always release (even on throw/cancel).
    public func withRuntime<T>(install: ModelInstall, priority: RequestPriority = .interactive, _ body: (BackendRuntime) async throws -> T) async throws -> T {
        let runtime = try await acquire(install: install, priority: priority)
        do {
            let result = try await body(runtime)
            release(modelID: install.id, measuredMemoryBytes: await runtime.metrics.memoryBytes)
            return result
        } catch {
            release(modelID: install.id, measuredMemoryBytes: nil)
            throw error
        }
    }

    // MARK: - Residency + load dedup

    private func ensureResident(install: ModelInstall) async throws -> BackendRuntime {
        if let resident = residents[install.id], let runtime = resident.runtime,
           resident.state != .unloaded, resident.state != .failed, resident.state != .unloading {
            // Crash recovery: a self-reporting runtime (persistent worker) that has died is dropped and
            // reloaded below, rather than handed out dead. Only when idle — an in-flight request will
            // surface the crash to its own caller.
            if let reporter = runtime as? ResidencyReporting, !reporter.isHealthy, resident.activeRequests == 0 {
                unloadResident(resident)
            } else {
                return runtime   // already warm/active/idle
            }
        }
        // Deduplicate concurrent loads of the same model.
        if let existing = loadingTasks[install.id] {
            return try await existing.value
        }

        let estimatedGB = estimator(install)
        do {
            try makeRoom(forModel: install.id, estimatedGB: estimatedGB)
        } catch RuntimeLifecycleError.overBudget {
            // The LLM won't fit even after evicting idle LLM residents. If a persistent speech runtime
            // is holding memory, drop it (async, in another actor) and retry once — so an LLM under
            // memory pressure reclaims speech rather than failing. `reclaim` calls back into
            // setExternalReservation(0), so the retry sees the freed budget.
            if externalReservationGB > 0, let reclaim = externalReclaim {
                await reclaim()
                try makeRoom(forModel: install.id, estimatedGB: estimatedGB)
            } else {
                throw RuntimeLifecycleError.overBudget(
                    modelID: install.id,
                    neededGB: (estimatedGB ?? 0) + effectiveExternalReserveGB(),
                    usableGB: usableBudgetGB ?? 0)
            }
        }

        let resident = residents[install.id] ?? Resident(install: install, estimatedGB: estimatedGB, now: clock())
        resident.estimatedGB = estimatedGB
        resident.state = .loading
        residents[install.id] = resident

        let loader = self.loader
        let task = Task<BackendRuntime, Error> { try await loader(install) }
        loadingTasks[install.id] = task
        do {
            let runtime = try await task.value
            loadingTasks[install.id] = nil
            resident.runtime = runtime
            resident.state = .warm
            resident.loadCount += 1
            resident.lastUsed = clock()
            return runtime
        } catch {
            loadingTasks[install.id] = nil
            resident.state = .failed
            resident.runtime = nil
            throw RuntimeLifecycleError.loadFailed(modelID: install.id, reason: error.localizedDescription)
        }
    }

    // MARK: - External (speech) memory reservation

    /// Report the live memory a non-LLM runtime (persistent speech/STT) is holding, so the LLM pool
    /// reserves it out of the budget. Pass `gigabytes: 0` to release. `reclaim`, when provided, is
    /// invoked by the pool to drop that runtime if an LLM otherwise can't fit; pass nil when there's
    /// nothing to reclaim (i.e. releasing).
    public func setExternalReservation(gigabytes gb: Double, reclaim: (@Sendable () async -> Void)?) {
        externalReservationGB = max(0, gb)
        externalReclaim = reclaim
    }

    /// The memory reserved for the external speech runtime: its live footprint when resident, else the
    /// static planning headroom from config. Exposed for status/tests.
    public func externalReservationGigabytes() -> Double { effectiveExternalReserveGB() }

    private func effectiveExternalReserveGB() -> Double { max(config.ttsReserveGB, externalReservationGB) }

    // MARK: - Budget + eviction

    private func makeRoom(forModel modelID: String, estimatedGB: Double?) throws {
        guard let usable = usableBudgetGB else {
            enforceCountLimit(excluding: modelID)
            return
        }
        let need = (estimatedGB ?? 0) + effectiveExternalReserveGB()
        func currentUsage() -> Double {
            residents.values.filter { $0.install.id != modelID }
                .reduce(0) { $0 + ($1.estimatedGB ?? 0) }
        }
        // Evict idle (non-active) LRU models until the new one fits and the count limit is met.
        while (currentUsage() + need) > usable || overCountLimit(excluding: modelID) {
            guard let victim = evictionCandidate(excluding: modelID) else { break }
            unloadResident(victim)
        }
        if (currentUsage() + need) > usable {
            throw RuntimeLifecycleError.overBudget(modelID: modelID, neededGB: need, usableGB: usable)
        }
    }

    private func enforceCountLimit(excluding modelID: String) {
        while overCountLimit(excluding: modelID) {
            guard let victim = evictionCandidate(excluding: modelID) else { break }
            unloadResident(victim)
        }
    }

    private func overCountLimit(excluding modelID: String) -> Bool {
        guard config.maxResidentModels > 0 else { return false }
        let residentCount = residents.values.filter {
            $0.install.id != modelID && ($0.state == .warm || $0.state == .active || $0.state == .idle || $0.state == .loading)
        }.count
        return residentCount >= config.maxResidentModels
    }

    /// Least-recently-used, non-active resident that can be evicted.
    private func evictionCandidate(excluding modelID: String) -> Resident? {
        residents.values
            .filter { $0.install.id != modelID && $0.activeRequests == 0 && ($0.state == .warm || $0.state == .idle) }
            .min { $0.lastUsed < $1.lastUsed }
    }

    private func unloadResident(_ resident: Resident) {
        resident.state = .unloading
        let runtime = resident.runtime
        resident.runtime = nil
        residents[resident.install.id] = nil
        if let runtime { Task { await runtime.unload() } }
    }

    /// Unload a specific model if it is not active. Returns true if it was unloaded.
    @discardableResult
    public func unload(modelID: String) -> Bool {
        guard let resident = residents[modelID], resident.activeRequests == 0 else { return false }
        unloadResident(resident)
        return true
    }

    /// Clean shutdown: unload every resident runtime, terminating any persistent workers so none are
    /// orphaned. Call this on host teardown (`esh serve`/chat exit). Unloads regardless of active
    /// requests — this is a shutdown, not an eviction.
    public func unloadAll() {
        for resident in Array(residents.values) {
            unloadResident(resident)
        }
    }

    /// Mark warm models idle if they've been unused past the idle timeout, and evict them.
    /// Returns the ids evicted.
    @discardableResult
    public func evictIdle() -> [String] {
        let cutoff = clock().addingTimeInterval(-config.idleTimeoutSeconds)
        var evicted: [String] = []
        for resident in residents.values where resident.activeRequests == 0 && resident.state == .warm {
            if resident.lastUsed < cutoff {
                resident.state = .idle
                unloadResident(resident)
                evicted.append(resident.install.id)
            }
        }
        return evicted
    }

    /// Memory-pressure reclaim: evict idle/warm non-active models (LRU first) until the estimated
    /// resident usage is under `targetGB` (or nothing more can be freed). Returns evicted ids.
    @discardableResult
    public func reclaimForPressure(targetGB: Double) -> [String] {
        var evicted: [String] = []
        func usage() -> Double { residents.values.reduce(0) { $0 + ($1.estimatedGB ?? 0) } }
        while usage() > targetGB, let victim = evictionCandidate(excluding: "") {
            unloadResident(victim)
            evicted.append(victim.install.id)
        }
        return evicted
    }

    // MARK: - Concurrency admission (priority-aware, cancellable)

    private func admit(priority: RequestPriority) async throws {
        if activeCount < config.maxConcurrentRequests {
            activeCount += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                insertWaiter(Waiter(id: id, priority: priority, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
        // Resumed => a slot was transferred to us (activeCount unchanged).
    }

    private func insertWaiter(_ waiter: Waiter) {
        // Interactive ahead of background; FIFO within the same priority.
        if let idx = waiters.firstIndex(where: { $0.priority < waiter.priority }) {
            waiters.insert(waiter, at: idx)
        } else {
            waiters.append(waiter)
        }
    }

    private func releaseSlot() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.continuation.resume()      // slot transfers to the waiter; activeCount unchanged
        } else {
            activeCount = max(0, activeCount - 1)
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let idx = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: idx)
        waiter.continuation.resume(throwing: RuntimeLifecycleError.cancelled)
    }

    // MARK: - Prewarm + status

    /// Load a model into the pool without an active request (optional prewarming).
    public func prewarm(install: ModelInstall) async throws {
        _ = try await ensureResident(install: install)
    }

    public func status() -> RuntimePoolStatus {
        let formatter = ISO8601DateFormatter()
        let infos = residents.values.map { r in
            ResidentModelInfo(
                modelID: r.install.id, backend: r.install.spec.backend, state: r.state.rawValue,
                // Prefer the runtime's own truthful residency (a persistent worker knows if its
                // weights are still loaded); fall back to the static probe otherwise.
                residency: residencyFor(r).rawValue,
                estimatedMemoryGB: r.estimatedGB, measuredMemoryBytes: r.measuredBytes,
                activeRequests: r.activeRequests, loadCount: r.loadCount,
                lastUsedISO8601: formatter.string(from: r.lastUsed)
            )
        }.sorted { $0.modelID < $1.modelID }
        let estUsage = residents.values.reduce(0.0) { $0 + ($1.estimatedGB ?? 0) }
        return RuntimePoolStatus(
            residents: infos, activeRequests: activeCount,
            estimatedResidentMemoryGB: (estUsage * 10).rounded() / 10,
            usableBudgetGB: usableBudgetGB,
            maxResidentModels: config.maxResidentModels,
            maxConcurrentRequests: config.maxConcurrentRequests,
            speechReservationGB: (effectiveExternalReserveGB() * 10).rounded() / 10
        )
    }

    /// Truthful residency for a resident: the runtime's own report when it can self-report (a
    /// persistent worker that knows whether its weights are still loaded), else the static probe.
    private func residencyFor(_ resident: Resident) -> RuntimeResidency {
        if let reporter = resident.runtime as? ResidencyReporting {
            return reporter.isHealthy ? reporter.residency : .handleCached
        }
        return residencyProbe(resident.install)
    }

    /// Ids of currently resident models (warm/active/idle) — for Scheduler awareness.
    public func residentModelIDs() -> [String] {
        residents.values.filter { $0.state == .warm || $0.state == .active || $0.state == .idle }.map { $0.install.id }
    }
}
