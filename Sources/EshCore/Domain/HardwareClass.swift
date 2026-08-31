import Foundation

/// Apple-Silicon unified-memory classes used to key recommendations. Constrained by actual memory,
/// not marketing chip names (chip generation is layered in as secondary evidence where available).
public enum HardwareClass: String, Codable, Sendable, CaseIterable {
    case gb8 = "8gb"
    case gb16 = "16gb"
    case gb24 = "24gb"
    case gb32 = "32-36gb"
    case gb48 = "48gb"
    case gb64 = "64gb"
    case gb96 = "96gb+"

    public init(totalMemoryGB: Double) {
        switch totalMemoryGB {
        case ..<12: self = .gb8
        case ..<20: self = .gb16
        case ..<28: self = .gb24
        case ..<44: self = .gb32
        case ..<56: self = .gb48
        case ..<80: self = .gb64
        default: self = .gb96
        }
    }

    public var displayName: String {
        switch self {
        case .gb8: return "8 GB"
        case .gb16: return "16 GB"
        case .gb24: return "24 GB"
        case .gb32: return "32–36 GB"
        case .gb48: return "48 GB"
        case .gb64: return "64 GB"
        case .gb96: return "96 GB+"
        }
    }
}

/// Recommendation profiles the Benchmark Lab scores separately (never one universal score).
public enum RecommendationProfile: String, Codable, Sendable, CaseIterable {
    case general
    case coding
    case reasoning
    case fast
    case lowMemory = "low-memory"
    case longContext = "long-context"
    case tools
    case bestQuality = "best-quality"

    public init?(cliValue: String) {
        switch cliValue.lowercased() {
        case "general", "chat", "balanced": self = .general
        case "coding", "code": self = .coding
        case "reasoning", "reason": self = .reasoning
        case "fast", "quick": self = .fast
        case "low-memory", "lowmemory", "low": self = .lowMemory
        case "long-context", "long", "longcontext": self = .longContext
        case "tools", "tool", "json", "structured": self = .tools
        case "best-quality", "best", "quality", "max": self = .bestQuality
        default: return nil
        }
    }

    public var title: String {
        switch self {
        case .general: return "General"
        case .coding: return "Coding"
        case .reasoning: return "Reasoning"
        case .fast: return "Fast"
        case .lowMemory: return "Low memory"
        case .longContext: return "Long context"
        case .tools: return "Tools / JSON"
        case .bestQuality: return "Best quality"
        }
    }
}

/// Where a recommendation's evidence comes from — never claim measured precision that doesn't exist.
public enum RecommendationEvidence: String, Codable, Sendable {
    case measuredLocal = "measured-local"      // benchmarked on THIS Mac (M1 harness)
    case measuredCurated = "measured-curated"  // benchmarked by esh dev on this hardware class
    case estimated                              // fit/capability-derived estimate, not yet benchmarked
}

/// One profile-specific recommendation for a hardware class. Feeds onboarding, `esh model
/// recommended`, Model Fit, and the Adaptive Scheduler.
public struct CuratedRecommendation: Codable, Sendable, Equatable {
    public var modelID: String
    public var repoID: String
    public var backend: BackendKind
    public var hardwareClass: HardwareClass
    public var profile: RecommendationProfile
    public var rank: Int
    public var fit: String                 // ModelFitClass raw value
    public var evidence: RecommendationEvidence
    public var qualityScore: Double?       // 0...1, present only when measured
    public var toolReliability: Double?    // 0...1, present only when measured
    public var medianDecodeTPS: Double?    // present only when measured
    public var peakMemoryGB: Double?
    public var maxRecommendedContext: Int?
    public var reasons: [String]

    public init(
        modelID: String, repoID: String, backend: BackendKind, hardwareClass: HardwareClass,
        profile: RecommendationProfile, rank: Int, fit: String, evidence: RecommendationEvidence,
        qualityScore: Double? = nil, toolReliability: Double? = nil, medianDecodeTPS: Double? = nil,
        peakMemoryGB: Double? = nil, maxRecommendedContext: Int? = nil, reasons: [String] = []
    ) {
        self.modelID = modelID; self.repoID = repoID; self.backend = backend
        self.hardwareClass = hardwareClass; self.profile = profile; self.rank = rank
        self.fit = fit; self.evidence = evidence; self.qualityScore = qualityScore
        self.toolReliability = toolReliability; self.medianDecodeTPS = medianDecodeTPS
        self.peakMemoryGB = peakMemoryGB; self.maxRecommendedContext = maxRecommendedContext
        self.reasons = reasons
    }
}

/// A versioned, machine-readable recommendation dataset (Benchmark Lab output). Independently
/// refreshable through the Living Catalog when that lands.
public struct CuratedRecommendationDataset: Codable, Sendable {
    public var datasetVersion: Int
    public var scoringVersion: Int
    public var generatedAtISO8601: String?
    public var recommendations: [CuratedRecommendation]

    public init(datasetVersion: Int, scoringVersion: Int, generatedAtISO8601: String? = nil, recommendations: [CuratedRecommendation]) {
        self.datasetVersion = datasetVersion
        self.scoringVersion = scoringVersion
        self.generatedAtISO8601 = generatedAtISO8601
        self.recommendations = recommendations
    }
}
