import Foundation

// esh 2.1 — Stage 4.2a: a unified, capability-agnostic performance-evidence record + a read-only index
// over the existing (siloed) benchmark stores. Additive: no selection behavior changes yet. This is the
// shared vocabulary a performance-aware Scheduler (4.2b/c) will consume so Auto can prefer a *practical*
// provider — memory fit ≠ useful performance. See 2_1_STAGE4_2_SCHEDULER_V2_DESIGN.md.

public struct CapabilityPerformanceEvidence: Codable, Sendable, Equatable {
    public var capability: CapabilityID
    public var providerID: String
    public var modelID: String?
    /// Cost-driving knobs (e.g. {"width":1024,"height":1024,"steps":8} or {"scale":4}).
    public var config: [String: JSONValue]
    public var coldMs: Double?
    public var warmMs: Double?
    public var secondsPerUnit: Double?
    public var unit: String                 // "image" | "video-second" | "audio-minute" | "1k-tokens"
    public var peakMemoryMB: Double?
    public var reliability: Double?          // 0…1 (validity rate / stable)
    public var measuredUnderMemoryPressure: Bool
    public var experimental: Bool
    public var note: String?

    public init(capability: CapabilityID, providerID: String, modelID: String?, config: [String: JSONValue] = [:],
                coldMs: Double? = nil, warmMs: Double? = nil, secondsPerUnit: Double? = nil, unit: String,
                peakMemoryMB: Double? = nil, reliability: Double? = nil,
                measuredUnderMemoryPressure: Bool = false, experimental: Bool = false, note: String? = nil) {
        self.capability = capability
        self.providerID = providerID
        self.modelID = modelID
        self.config = config
        self.coldMs = coldMs
        self.warmMs = warmMs
        self.secondsPerUnit = secondsPerUnit
        self.unit = unit
        self.peakMemoryMB = peakMemoryMB
        self.reliability = reliability
        self.measuredUnderMemoryPressure = measuredUnderMemoryPressure
        self.experimental = experimental
        self.note = note
    }
}

public enum EvidencePreference: Sendable { case fastest, mostReliable }

/// Read-only accessor that merges the existing benchmark stores into the unified vocabulary. Grows as more
/// runners persist evidence; today it adapts image-generation benchmarks and the LLM benchmark lab.
public struct CapabilityEvidenceIndex: Sendable {
    public let evidence: [CapabilityPerformanceEvidence]

    public init(evidence: [CapabilityPerformanceEvidence]) { self.evidence = evidence }

    public init(root: PersistenceRoot) {
        var acc: [CapabilityPerformanceEvidence] = []
        acc.append(contentsOf: ImageGenerationBenchmarkStore(root: root).load().benchmarks.map(Self.adapt))
        acc.append(contentsOf: ModelBenchmarkLabStore(root: root).load().evidence.compactMap(Self.adapt))
        // image.upscale evidence is already stored in the unified vocabulary (no adapter needed).
        acc.append(contentsOf: ImageUpscaleBenchmarkStore(root: root).load().evidence)
        self.evidence = acc
    }

    public func all(capability: CapabilityID) -> [CapabilityPerformanceEvidence] {
        evidence.filter { $0.capability == capability }
    }

    /// Best evidence for a capability at (optionally) a matching config. Excludes experimental and
    /// under-pressure samples when cleaner ones exist. `prefer` breaks ties by speed or reliability.
    public func best(capability: CapabilityID, config: [String: JSONValue] = [:],
                     prefer: EvidencePreference = .fastest) -> CapabilityPerformanceEvidence? {
        var pool = all(capability: capability).filter { !$0.experimental }
        if !config.isEmpty {
            let matches = pool.filter { e in config.allSatisfy { k, v in e.config[k] == v } }
            if !matches.isEmpty { pool = matches }
        }
        let clean = pool.filter { !$0.measuredUnderMemoryPressure }
        if !clean.isEmpty { pool = clean }
        guard !pool.isEmpty else { return nil }
        switch prefer {
        case .fastest:
            return pool.min { (a, b) in (a.secondsPerUnit ?? .greatestFiniteMagnitude) < (b.secondsPerUnit ?? .greatestFiniteMagnitude) }
        case .mostReliable:
            return pool.max { (a, b) in (a.reliability ?? 0) < (b.reliability ?? 0) }
        }
    }

    // MARK: - Adapters (keep the typed stores; normalize on read)

    static func adapt(_ b: ImageGenerationBenchmark) -> CapabilityPerformanceEvidence {
        let reliability = b.totalRuns > 0 ? Double(b.outputValidCount) / Double(b.totalRuns) : nil
        return CapabilityPerformanceEvidence(
            capability: .imageGenerate, providerID: "image-generation", modelID: b.modelID,
            config: ["width": .int(b.requestedWidth), "height": .int(b.requestedHeight), "steps": .int(b.steps)],
            coldMs: b.coldLoadAndGenerateMs, warmMs: b.warmGenerateMsMedian, secondsPerUnit: b.secondsPerImageMedian,
            unit: "image", peakMemoryMB: b.peakMemoryMB, reliability: reliability,
            measuredUnderMemoryPressure: b.measuredUnderMemoryPressure, experimental: false, note: b.note)
    }

    static func adapt(_ b: ModelBenchmarkEvidence) -> CapabilityPerformanceEvidence? {
        let tps = b.performance.decodeTokensPerSecondMedian
        let secPer1k = tps.map { $0 > 0 ? 1000.0 / $0 : nil } ?? nil
        return CapabilityPerformanceEvidence(
            capability: .languageGenerate, providerID: "language-generate", modelID: b.modelID,
            config: [:], warmMs: nil, secondsPerUnit: secPer1k, unit: "1k-tokens",
            peakMemoryMB: b.performance.peakMemoryMB,
            reliability: b.quality.total > 0 ? Double(b.quality.passed) / Double(b.quality.total) : nil,
            measuredUnderMemoryPressure: false, experimental: !b.stable, note: nil)
    }
}
