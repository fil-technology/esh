import Foundation

/// Whether keeping a runtime "warm" actually keeps the expensive model weights resident, or only
/// caches a lightweight handle while the backend reloads weights on each call. esh must not present
/// handle-caching as true model warmth.
public enum RuntimeResidency: String, Codable, Sendable {
    /// Model weights stay resident in memory across requests (true warmth).
    case weightsResident = "weights-resident"
    /// Only a lightweight runtime handle is cached; the backend reloads weights per call (e.g. the
    /// current MLX/llama.cpp subprocess-per-generate design). Not true weight residency.
    case handleCached = "handle-cached"
}

/// A runtime that can truthfully report its own residency + health (e.g. a persistent worker that
/// knows whether its weights are still loaded). The lifecycle manager prefers this over a static
/// probe so a crashed/unloaded worker is never reported as weights-resident.
/// A runtime that keeps memory resident between requests beyond its weights (a persistent worker's session
/// KV/prefix caches) and can release it on demand. The warm pool counts it against its budget, releases idle
/// caches before evicting whole models, and releases them on memory pressure. Releasing must never affect an
/// in-flight request (the persistent MLX worker processes the release between requests).
public protocol CacheMemoryReporting: Sendable {
    func residentCacheBytes() async -> Int64
    func releaseCaches() async
}

public protocol ResidencyReporting {
    var residency: RuntimeResidency { get }
    var isHealthy: Bool { get }
}

/// Lifecycle state of a model runtime in the warm pool.
public enum ModelRuntimeState: String, Codable, Sendable {
    case unloaded    // not resident
    case loading     // a load is in flight
    case warm        // resident, ready, no active request
    case active      // resident, currently serving a request
    case idle        // resident, warm, past its last use (eviction candidate)
    case unloading   // being torn down
    case failed      // last load failed
}

/// Request priority. Interactive requests are admitted ahead of background ones under contention.
public enum RequestPriority: String, Codable, Sendable, Comparable {
    case background
    case interactive
    public static func < (lhs: RequestPriority, rhs: RequestPriority) -> Bool {
        lhs == .background && rhs == .interactive
    }
}

/// Configuration for the runtime lifecycle / warm pool.
public struct RuntimeLifecycleConfig: Sendable {
    /// Max models kept resident at once (0 = unlimited, still bounded by memory budget).
    public var maxResidentModels: Int
    /// After this many seconds without use a warm model becomes idle (eviction candidate).
    public var idleTimeoutSeconds: Double
    /// Memory kept free for the OS/other apps, on top of model estimates.
    public var memorySafetyReserveGB: Double
    /// Max concurrent in-flight generation requests across the pool.
    public var maxConcurrentRequests: Int
    /// Reserved headroom for a resident TTS/voice session (keeps text+speech coexistence honest).
    public var ttsReserveGB: Double

    public init(
        maxResidentModels: Int = 3,
        idleTimeoutSeconds: Double = 300,
        memorySafetyReserveGB: Double = 3,
        maxConcurrentRequests: Int = 2,
        ttsReserveGB: Double = 0
    ) {
        self.maxResidentModels = maxResidentModels
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.memorySafetyReserveGB = memorySafetyReserveGB
        self.maxConcurrentRequests = maxConcurrentRequests
        self.ttsReserveGB = ttsReserveGB
    }
}

/// A resident model's public status (for doctor/status/scheduler). Memory is honest about whether
/// it is an estimate (pre-run) or a measured value (from a real generation).
public struct ResidentModelInfo: Codable, Sendable, Equatable {
    public var modelID: String
    public var backend: BackendKind
    public var state: String                 // ModelRuntimeState raw value
    /// Truthful residency: whether "warm" means weights-resident or only handle-cached.
    public var residency: String             // RuntimeResidency raw value
    public var estimatedMemoryGB: Double?
    public var measuredMemoryBytes: Int64?
    public var activeRequests: Int
    public var loadCount: Int
    public var lastUsedISO8601: String?

    public init(modelID: String, backend: BackendKind, state: String, residency: String, estimatedMemoryGB: Double?, measuredMemoryBytes: Int64?, activeRequests: Int, loadCount: Int, lastUsedISO8601: String?) {
        self.modelID = modelID
        self.backend = backend
        self.state = state
        self.residency = residency
        self.estimatedMemoryGB = estimatedMemoryGB
        self.measuredMemoryBytes = measuredMemoryBytes
        self.activeRequests = activeRequests
        self.loadCount = loadCount
        self.lastUsedISO8601 = lastUsedISO8601
    }
}

/// Snapshot of the whole pool, for doctor / status / scheduler awareness.
public struct RuntimePoolStatus: Codable, Sendable, Equatable {
    public var residents: [ResidentModelInfo]
    public var residentCount: Int
    public var activeRequests: Int
    public var estimatedResidentMemoryGB: Double
    public var usableBudgetGB: Double?
    public var maxResidentModels: Int
    public var maxConcurrentRequests: Int
    /// Memory reserved out of the budget for the persistent speech runtime (its live footprint when a
    /// worker is resident, else the static planning headroom). 0 when speech isn't loaded. (M12)
    public var speechReservationGB: Double
    /// Memory resident runtimes report holding in caches between requests (persistent KV/prefix caches),
    /// already included in `estimatedResidentMemoryGB`. nil when no runtime reports caches.
    public var residentCacheGB: Double?

    public init(residents: [ResidentModelInfo], activeRequests: Int, estimatedResidentMemoryGB: Double, usableBudgetGB: Double?, maxResidentModels: Int, maxConcurrentRequests: Int, speechReservationGB: Double = 0, residentCacheGB: Double? = nil) {
        self.residents = residents
        self.residentCount = residents.count
        self.activeRequests = activeRequests
        self.estimatedResidentMemoryGB = estimatedResidentMemoryGB
        self.usableBudgetGB = usableBudgetGB
        self.maxResidentModels = maxResidentModels
        self.maxConcurrentRequests = maxConcurrentRequests
        self.speechReservationGB = speechReservationGB
        self.residentCacheGB = residentCacheGB
    }
}

public enum RuntimeLifecycleError: Error, LocalizedError, Equatable {
    case overBudget(modelID: String, neededGB: Double, usableGB: Double)
    case cancelled
    case loadFailed(modelID: String, reason: String)
    /// A request's KV-cache growth (prompt + max new tokens) cannot fit safely even after idle caches and idle models
    /// were reclaimed. Nothing active was touched; the caller should shorten the context or free memory.
    case insufficientMemoryForContext(modelID: String, neededGB: Double, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .overBudget(modelID, needed, usable):
            return String(format: "Loading %@ (~%.1f GB) would exceed the safe memory budget (~%.1f GB usable). Unload another model or use a smaller one.", modelID, needed, usable)
        case .cancelled:
            return "The request was cancelled."
        case let .loadFailed(modelID, reason):
            return "Failed to load \(modelID): \(reason)"
        case let .insufficientMemoryForContext(modelID, needed, reason):
            return String(format: "Not enough memory to run this request on %@: its context needs ~%.1f GB more KV cache (%@). Shorten the conversation or max_tokens, close other apps, or use a smaller model.", modelID, needed, reason)
        }
    }
}
