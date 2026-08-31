import Foundation

/// Identity a benchmark result is keyed by, so stale results are never applied to a different
/// machine/model/runtime. A key mismatch is the invalidation mechanism: results that don't match
/// the current identity are simply not returned.
public struct OptimizationProfileKey: Codable, Hashable, Sendable {
    public var hardwareFingerprint: String
    public var modelID: String
    public var modelRevision: String?
    public var backend: String
    public var runtimeVersion: String?
    public var optimizationSchemaVersion: Int

    public init(
        hardwareFingerprint: String,
        modelID: String,
        modelRevision: String? = nil,
        backend: String,
        runtimeVersion: String? = nil,
        optimizationSchemaVersion: Int = OptimizationSchema.version
    ) {
        self.hardwareFingerprint = hardwareFingerprint
        self.modelID = modelID
        self.modelRevision = modelRevision
        self.backend = backend
        self.runtimeVersion = runtimeVersion
        self.optimizationSchemaVersion = optimizationSchemaVersion
    }

    public static func hardwareFingerprint(from host: HostMachineProfile?) -> String {
        let chip = host?.chipDescription ?? "Apple Silicon"
        let ram = host?.totalMemoryGB.map { "\(Int($0.rounded()))GB" } ?? "?GB"
        return "\(chip)|\(ram)"
    }

    /// Stable slug for the on-disk filename.
    public var slug: String {
        let raw = "\(hardwareFingerprint)|\(modelID)|\(modelRevision ?? "-")|\(backend)|\(runtimeVersion ?? "-")|v\(optimizationSchemaVersion)"
        return Fingerprint.sha256([raw])
    }
}

/// One benchmark measurement (a single run's metrics). All optional so partial measurement is
/// honestly represented rather than fabricated.
public struct BenchmarkMetrics: Codable, Sendable, Equatable {
    // Performance
    public var coldStartMs: Double?
    public var ttftMs: Double?
    public var prefillTokensPerSec: Double?
    public var decodeTokensPerSec: Double?
    public var endToEndMs: Double?
    public var tokensGenerated: Int?
    public var speculativeAcceptanceRate: Double?
    public var promptCacheLoadMs: Double?
    // Memory
    public var memoryBeforeBytes: Int64?
    public var peakMemoryBytes: Int64?
    public var memoryAfterBytes: Int64?
    public var kvCacheBytes: Int64?
    // Quality / correctness / stability
    public var jsonValidityRate: Double?
    public var toolCallValidityRate: Double?
    public var distributionEquivalentToBaseline: Bool?
    public var qualityScore: Double?      // 0...1, strategy-appropriate proxy
    public var errorCount: Int

    public init(
        coldStartMs: Double? = nil, ttftMs: Double? = nil,
        prefillTokensPerSec: Double? = nil, decodeTokensPerSec: Double? = nil,
        endToEndMs: Double? = nil, tokensGenerated: Int? = nil,
        speculativeAcceptanceRate: Double? = nil, promptCacheLoadMs: Double? = nil,
        memoryBeforeBytes: Int64? = nil, peakMemoryBytes: Int64? = nil,
        memoryAfterBytes: Int64? = nil, kvCacheBytes: Int64? = nil,
        jsonValidityRate: Double? = nil, toolCallValidityRate: Double? = nil,
        distributionEquivalentToBaseline: Bool? = nil, qualityScore: Double? = nil,
        errorCount: Int = 0
    ) {
        self.coldStartMs = coldStartMs; self.ttftMs = ttftMs
        self.prefillTokensPerSec = prefillTokensPerSec; self.decodeTokensPerSec = decodeTokensPerSec
        self.endToEndMs = endToEndMs; self.tokensGenerated = tokensGenerated
        self.speculativeAcceptanceRate = speculativeAcceptanceRate; self.promptCacheLoadMs = promptCacheLoadMs
        self.memoryBeforeBytes = memoryBeforeBytes; self.peakMemoryBytes = peakMemoryBytes
        self.memoryAfterBytes = memoryAfterBytes; self.kvCacheBytes = kvCacheBytes
        self.jsonValidityRate = jsonValidityRate; self.toolCallValidityRate = toolCallValidityRate
        self.distributionEquivalentToBaseline = distributionEquivalentToBaseline
        self.qualityScore = qualityScore; self.errorCount = errorCount
    }
}

/// A benchmarked (strategy × workload × context) result: median summary plus preserved raw samples.
public struct OptimizationBenchmarkResult: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var key: OptimizationProfileKey
    public var category: OptimizationCategory
    public var strategyID: String
    public var workload: OptimizationWorkload
    public var contextBucket: ContextBucket
    public var median: BenchmarkMetrics
    public var samples: [BenchmarkMetrics]
    public var recordedAtISO8601: String
    public var eshVersion: String?
    public var gitSHA: String?

    public init(
        id: UUID = UUID(),
        key: OptimizationProfileKey,
        category: OptimizationCategory,
        strategyID: String,
        workload: OptimizationWorkload,
        contextBucket: ContextBucket,
        median: BenchmarkMetrics,
        samples: [BenchmarkMetrics] = [],
        recordedAtISO8601: String,
        eshVersion: String? = nil,
        gitSHA: String? = nil
    ) {
        self.id = id
        self.key = key
        self.category = category
        self.strategyID = strategyID
        self.workload = workload
        self.contextBucket = contextBucket
        self.median = median
        self.samples = samples
        self.recordedAtISO8601 = recordedAtISO8601
        self.eshVersion = eshVersion
        self.gitSHA = gitSHA
    }
}

/// Persists benchmark evidence on the internal state root (lightweight metadata, always available).
public struct OptimizationProfileStore: Sendable {
    private let directoryURL: URL

    public init(root: PersistenceRoot = .default()) {
        self.directoryURL = root.stateRootURL.appendingPathComponent("optimization", isDirectory: true)
    }

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public func save(_ result: OptimizationBenchmarkResult) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let url = directoryURL.appendingPathComponent("\(result.key.slug)-\(result.id.uuidString).json")
        try JSONCoding.encoder.encode(result).write(to: url, options: .atomic)
    }

    public func allResults() -> [OptimizationBenchmarkResult] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: nil
        ) else { return [] }
        return entries
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONCoding.decoder.decode(OptimizationBenchmarkResult.self, from: Data(contentsOf: $0)) }
    }

    /// Results matching the given identity (natural invalidation: mismatched keys are excluded).
    public func results(for key: OptimizationProfileKey, workload: OptimizationWorkload?, context: ContextBucket?) -> [OptimizationBenchmarkResult] {
        allResults().filter { result in
            result.key == key
                && (workload == nil || result.workload == workload)
                && (context == nil || result.contextBucket == context)
        }
    }

    /// Whether any evidence exists for the identity (used to decide auto vs conservative fallback).
    public func hasEvidence(for key: OptimizationProfileKey) -> Bool {
        allResults().contains { $0.key == key }
    }

    public func reset(key: OptimizationProfileKey) throws {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(key.slug) {
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
