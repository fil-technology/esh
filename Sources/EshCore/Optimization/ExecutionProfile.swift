import Foundation

/// A resolved, serializable plan describing exactly which optimizations will run for a request,
/// and *why*. Human-readable and stable-JSON for Ashex/external clients; attachable to run/inference
/// diagnostics. This is the boundary output of the OptimizationPlanner and the input the backend
/// execution layer honors.
public struct ExecutionProfile: Codable, Sendable, Equatable, Hashable {
    public var schemaVersion: Int
    public var backend: BackendKind
    public var model: String
    public var performanceMode: PerformanceMode
    public var workload: OptimizationWorkload
    public var contextTokens: Int?
    public var contextBucket: ContextBucket?

    /// category rawValue -> chosen strategy id (e.g. "kv-cache": "kv.turbo").
    public var selections: [String: String]
    /// Ordered, human-readable rationale for each decision.
    public var reasons: [String]
    /// True when at least one non-baseline selection was backed by local measured evidence.
    public var evidenceBacked: Bool
    /// Version of the local optimization profile DB consulted (nil if none available).
    public var benchmarkProfileVersion: Int?
    /// Truthful runtime residency for this execution (`weights-resident` vs `handle-cached`), or nil
    /// when the runtime does not report it. Lets callers see whether the model's weights were actually
    /// kept in memory (persistent worker) or reloaded for this request.
    public var residency: String?
    /// Realized prompt-cache outcome for this execution (true = a cached prefix was reused), or nil
    /// when the runtime does not report it. Distinct from the chosen cache strategy in `selections`.
    public var cacheHit: Bool?

    public init(
        schemaVersion: Int = OptimizationSchema.version,
        backend: BackendKind,
        model: String,
        performanceMode: PerformanceMode,
        workload: OptimizationWorkload,
        contextTokens: Int? = nil,
        selections: [String: String] = [:],
        reasons: [String] = [],
        evidenceBacked: Bool = false,
        benchmarkProfileVersion: Int? = nil,
        residency: String? = nil,
        cacheHit: Bool? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.backend = backend
        self.model = model
        self.performanceMode = performanceMode
        self.workload = workload
        self.contextTokens = contextTokens
        self.contextBucket = contextTokens.map(ContextBucket.init(tokens:))
        self.selections = selections
        self.reasons = reasons
        self.evidenceBacked = evidenceBacked
        self.benchmarkProfileVersion = benchmarkProfileVersion
        self.residency = residency
        self.cacheHit = cacheHit
    }

    public func strategyID(for category: OptimizationCategory) -> String? {
        selections[category.rawValue]
    }

    /// Compact one-line summary, e.g. "mlx · auto · kv=kv.raw prompt=prompt.reuse".
    public var summaryLine: String {
        let opt = OptimizationCategory.allCases
            .compactMap { cat -> String? in
                guard let id = selections[cat.rawValue] else { return nil }
                return "\(cat.rawValue)=\(id)"
            }
            .joined(separator: " ")
        return "\(backend.rawValue) · \(performanceMode.rawValue) · \(opt)"
    }

    /// Map the resolved KV-cache strategy back onto esh's existing CacheMode knob so the backend
    /// execution layer (which already honors CacheMode) can consume the profile without a rewrite.
    public var cacheMode: CacheMode {
        switch strategyID(for: .kvCache) {
        case OptimizationStrategyRegistry.kvTurbo.id: return .turbo
        case OptimizationStrategyRegistry.kvTriAttention.id: return .triattention
        default: return .raw
        }
    }
}
