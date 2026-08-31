import Foundation

/// Provenance for a benchmark run — so evidence is never anonymous or undated. Every field records
/// exactly what was measured, on what, when.
public struct BenchmarkProvenance: Codable, Hashable, Sendable {
    public var dateISO8601: String
    public var eshVersion: String?
    public var runtimeVersion: String?
    public var hardware: String          // e.g. "Apple M1 Pro / 32 GB"
    public var suiteVersion: Int
    public var quantization: String?
    public var contextTokens: Int?

    public init(dateISO8601: String, eshVersion: String?, runtimeVersion: String?,
                hardware: String, suiteVersion: Int, quantization: String?, contextTokens: Int?) {
        self.dateISO8601 = dateISO8601
        self.eshVersion = eshVersion
        self.runtimeVersion = runtimeVersion
        self.hardware = hardware
        self.suiteVersion = suiteVersion
        self.quantization = quantization
        self.contextTokens = contextTokens
    }
}

/// Measured performance for one model (real runtime metrics — never fabricated; nil when unmeasured).
public struct BenchmarkPerformance: Codable, Hashable, Sendable {
    public var ttftMillisecondsMedian: Double?
    public var decodeTokensPerSecondMedian: Double?
    public var peakMemoryMB: Double?
    public var modelDiskBytes: Int64?

    public init(ttftMillisecondsMedian: Double? = nil, decodeTokensPerSecondMedian: Double? = nil,
                peakMemoryMB: Double? = nil, modelDiskBytes: Int64? = nil) {
        self.ttftMillisecondsMedian = ttftMillisecondsMedian
        self.decodeTokensPerSecondMedian = decodeTokensPerSecondMedian
        self.peakMemoryMB = peakMemoryMB
        self.modelDiskBytes = modelDiskBytes
    }
}

/// One deterministic quality probe result.
public struct BenchmarkProbeResult: Codable, Hashable, Sendable {
    public var id: String
    public var category: String          // reasoning/instruction/structured/coding/general
    public var passed: Bool
    public var reply: String?            // truncated, for auditability
    public var error: String?

    public init(id: String, category: String, passed: Bool, reply: String? = nil, error: String? = nil) {
        self.id = id
        self.category = category
        self.passed = passed
        self.reply = reply
        self.error = error
    }
}

/// Aggregated, deterministic quality signal for one model.
public struct BenchmarkQuality: Codable, Hashable, Sendable {
    public var passed: Int
    public var total: Int
    public var probes: [BenchmarkProbeResult]

    public init(passed: Int, total: Int, probes: [BenchmarkProbeResult]) {
        self.passed = passed
        self.total = total
        self.probes = probes
    }

    /// Pass rate per category (0...1), for profile-specific ranking (coding/reasoning/…).
    public var categoryPassRate: [String: Double] {
        var byCat: [String: (pass: Int, total: Int)] = [:]
        for p in probes {
            var e = byCat[p.category] ?? (0, 0)
            e.total += 1
            if p.passed { e.pass += 1 }
            byCat[p.category] = e
        }
        return byCat.mapValues { $0.total > 0 ? Double($0.pass) / Double($0.total) : 0 }
    }
}

/// Locally measured evidence for one model. This is the machine-readable, versioned unit the Model
/// Benchmark Lab produces and that recommendations/Model Fit/Scheduler can consult — local measured
/// evidence overriding generic curated guidance when present.
public struct ModelBenchmarkEvidence: Codable, Hashable, Sendable {
    public var modelID: String
    public var backend: BackendKind
    public var provenance: BenchmarkProvenance
    public var performance: BenchmarkPerformance
    public var quality: BenchmarkQuality
    /// True when the model ran without error across the probes (basic stability).
    public var stable: Bool

    public init(modelID: String, backend: BackendKind, provenance: BenchmarkProvenance,
                performance: BenchmarkPerformance, quality: BenchmarkQuality, stable: Bool) {
        self.modelID = modelID
        self.backend = backend
        self.provenance = provenance
        self.performance = performance
        self.quality = quality
        self.stable = stable
    }
}

/// A versioned collection of local benchmark evidence.
public struct ModelBenchmarkDataset: Codable, Hashable, Sendable {
    public static let schemaVersion = 1
    public var schemaVersion: Int
    public var evidence: [ModelBenchmarkEvidence]

    public init(schemaVersion: Int = ModelBenchmarkDataset.schemaVersion, evidence: [ModelBenchmarkEvidence] = []) {
        self.schemaVersion = schemaVersion
        self.evidence = evidence
    }

    public func evidence(for modelID: String) -> ModelBenchmarkEvidence? {
        evidence.first { $0.modelID == modelID }
    }
}
