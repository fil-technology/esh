import Foundation

// esh 2.1 — Router Auto evidence + policy (spec 86eyucfbu §8/§9/§13). Versioned, per-router benchmark
// evidence, and an EXPLAINABLE, conservative policy that picks the Tier-1 router from measured facts — not
// a hard-coded preference. Independent validation remains authoritative regardless of which router wins.

public struct RouterEvidence: Codable, Sendable, Equatable {
    public var router: String                 // "tier0" | "resident-llm" | "apple-foundation" | "functiongemma"
    public var mode: String                   // "tier0" | "tier1" | "hybrid"
    public var available: Bool
    public var modelOrProvider: String?       // exact model id / Apple provider provenance
    public var runtime: String?               // mlx / apple-foundation / rules
    // Metrics (from RoutingMetrics; only measured values persisted)
    public var total: Int
    public var capabilitySelectionAccuracy: Double
    public var falseExecutionRate: Double
    public var conservativeScore: Double
    public var clarifyRecall: Double
    public var argumentAccuracy: Double
    public var enAccuracy: Double
    public var ruAccuracy: Double
    public var heAccuracy: Double
    public var warmLatencyMsMedian: Double?
    public var coldLatencyMs: Double?
    public var memoryMB: Double?
    public var downloadMB: Int?
    // Provenance / freshness (§13)
    public var hardware: String
    public var osVersion: String?
    public var eshVersion: String?
    public var capabilitySchemaVersion: Int
    public var datasetVersion: Int
    public var dateISO8601: String

    public init(router: String, mode: String, available: Bool, modelOrProvider: String? = nil, runtime: String? = nil,
                total: Int = 0, capabilitySelectionAccuracy: Double = 0, falseExecutionRate: Double = 0,
                conservativeScore: Double = 0, clarifyRecall: Double = 0, argumentAccuracy: Double = 0,
                enAccuracy: Double = 0, ruAccuracy: Double = 0, heAccuracy: Double = 0,
                warmLatencyMsMedian: Double? = nil, coldLatencyMs: Double? = nil, memoryMB: Double? = nil, downloadMB: Int? = nil,
                hardware: String, osVersion: String? = nil, eshVersion: String? = nil,
                capabilitySchemaVersion: Int, datasetVersion: Int, dateISO8601: String) {
        self.router = router; self.mode = mode; self.available = available; self.modelOrProvider = modelOrProvider
        self.runtime = runtime; self.total = total; self.capabilitySelectionAccuracy = capabilitySelectionAccuracy
        self.falseExecutionRate = falseExecutionRate; self.conservativeScore = conservativeScore
        self.clarifyRecall = clarifyRecall; self.argumentAccuracy = argumentAccuracy
        self.enAccuracy = enAccuracy; self.ruAccuracy = ruAccuracy; self.heAccuracy = heAccuracy
        self.warmLatencyMsMedian = warmLatencyMsMedian; self.coldLatencyMs = coldLatencyMs
        self.memoryMB = memoryMB; self.downloadMB = downloadMB; self.hardware = hardware; self.osVersion = osVersion
        self.eshVersion = eshVersion; self.capabilitySchemaVersion = capabilitySchemaVersion
        self.datasetVersion = datasetVersion; self.dateISO8601 = dateISO8601
    }

    /// Evidence is stale when the components that materially affect routing change (esp. Apple FM after OS
    /// updates, or the capability schema / dataset). Freshness is judged by the caller against current values.
    public func isFresh(currentSchemaVersion: Int, currentDatasetVersion: Int, currentOS: String?) -> Bool {
        capabilitySchemaVersion == currentSchemaVersion && datasetVersion == currentDatasetVersion
            && (osVersion == nil || currentOS == nil || osVersion == currentOS)
    }
}

public struct RouterEvidenceDataset: Codable, Sendable {
    public static let schemaVersion = 1
    public var schemaVersion: Int
    public var evidence: [RouterEvidence]
    public init(schemaVersion: Int = RouterEvidenceDataset.schemaVersion, evidence: [RouterEvidence] = []) {
        self.schemaVersion = schemaVersion; self.evidence = evidence
    }
}

public struct RouterEvidenceStore: Sendable {
    private let fileURL: URL
    public init(root: PersistenceRoot) { self.fileURL = root.benchmarksURL.appendingPathComponent("router-evidence.json") }
    public func load() -> RouterEvidenceDataset {
        guard let d = try? Data(contentsOf: fileURL),
              let ds = try? JSONCoding.decoder.decode(RouterEvidenceDataset.self, from: d) else { return RouterEvidenceDataset() }
        return ds
    }
    public func save(_ ds: RouterEvidenceDataset) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encoder.encode(ds).write(to: fileURL, options: .atomic)
    }
    @discardableResult
    public func upsert(_ e: RouterEvidence) throws -> RouterEvidenceDataset {
        var ds = load(); ds.evidence.removeAll { $0.router == e.router && $0.mode == e.mode }; ds.evidence.append(e); try save(ds); return ds
    }
}

/// The explainable Router Auto policy: pick the Tier-1 semantic router from evidence. Conservative — a
/// router is eligible only if it is available, fresh, and MEETS A FALSE-EXECUTION CEILING; among eligible
/// routers it prefers the best conservative score, tie-broken by lower latency. Returns a decision + reasons.
public struct RouterAutoPolicy: Sendable {
    public struct Decision: Sendable, Equatable {
        public var chosenRouter: String?      // nil → no eligible semantic router → Tier-0 + clarify only
        public var reasons: [String]
    }
    /// Max tolerated false-execution rate for a Tier-1 router (spec §2/§9: safety first).
    public let falseExecutionCeiling: Double
    public init(falseExecutionCeiling: Double = 0.02) { self.falseExecutionCeiling = falseExecutionCeiling }

    public func choose(from evidence: [RouterEvidence], currentSchemaVersion: Int, currentDatasetVersion: Int,
                       currentOS: String?) -> Decision {
        var reasons: [String] = []
        // Tier-0 is the free, instant, safe baseline. A semantic router must BEAT it (higher conservative
        // score) to be worth its latency/memory — otherwise Router Auto stays on Tier-0 + clarification.
        let tier0Score = evidence.first(where: { $0.mode == "tier0" })?.conservativeScore ?? -.greatestFiniteMagnitude
        // The PRODUCTION path is the ambiguity-gated hybrid (Tier-0 authority + escalate only `unresolved` +
        // Safety Validator), so evaluate a router's `hybrid-gated` evidence when present; else fall back to its
        // pure `tier1` measurement. One candidate per router (gated preferred).
        var byRouter: [String: RouterEvidence] = [:]
        for e in evidence where e.router != "tier0" && (e.mode == "hybrid-gated" || e.mode == "tier1") {
            if byRouter[e.router]?.mode == "hybrid-gated" { continue }
            if e.mode == "hybrid-gated" || byRouter[e.router] == nil { byRouter[e.router] = e }
        }
        let candidates = Array(byRouter.values)
        let eligible = candidates.filter { e in
            guard e.available else { reasons.append("\(e.router): unavailable"); return false }
            guard e.isFresh(currentSchemaVersion: currentSchemaVersion, currentDatasetVersion: currentDatasetVersion, currentOS: currentOS) else {
                reasons.append("\(e.router): evidence stale — re-benchmark"); return false }
            guard e.falseExecutionRate <= falseExecutionCeiling else {
                reasons.append("\(e.router): false-exec \(String(format: "%.0f%%", e.falseExecutionRate*100)) > ceiling"); return false }
            guard e.conservativeScore > tier0Score else {
                reasons.append("\(e.router): score \(String(format: "%.2f", e.conservativeScore)) ≤ Tier-0 baseline \(String(format: "%.2f", tier0Score)) — not worth the cost"); return false }
            return true
        }
        guard let best = eligible.max(by: { a, b in
            if a.conservativeScore != b.conservativeScore { return a.conservativeScore < b.conservativeScore }
            return (a.warmLatencyMsMedian ?? .greatestFiniteMagnitude) > (b.warmLatencyMsMedian ?? .greatestFiniteMagnitude)
        }) else {
            reasons.append("no eligible Tier-1 router → Tier-0 + clarification only")
            return Decision(chosenRouter: nil, reasons: reasons)
        }
        reasons.append("chose \(best.router): score \(String(format: "%.2f", best.conservativeScore)), false-exec \(String(format: "%.0f%%", best.falseExecutionRate*100)), warm \(best.warmLatencyMsMedian.map { String(format: "%.0fms", $0) } ?? "?")")
        return Decision(chosenRouter: best.router, reasons: reasons)
    }
}
