import Foundation

/// Fit classification for running a model on this Mac. Ordered from best to worst; only
/// `unsupported` is a hard block — the rest are soft gates the user can override.
public enum ModelFitClass: String, Codable, Sendable, CaseIterable {
    case comfortable   // fits with generous headroom
    case fits          // fits within the safe budget
    case tight         // fits only into available/near-total memory — warn + confirm
    case unlikely      // exceeds usable memory — strong warn + explicit expert confirm
    case unsupported   // genuine technical incompatibility (backend/arch/macOS) — block
    case unknown       // not enough metadata to judge — explain + allow deliberate override

    public var requiresConfirmation: Bool {
        switch self {
        case .tight, .unlikely, .unknown: return true
        case .comfortable, .fits, .unsupported: return false
        }
    }

    public var isBlocked: Bool { self == .unsupported }

    public var headline: String {
        switch self {
        case .comfortable: return "Comfortable — plenty of headroom"
        case .fits: return "Fits — within the safe memory budget"
        case .tight: return "Tight — expect memory pressure"
        case .unlikely: return "Unlikely to run well — may swap or fail"
        case .unsupported: return "Unsupported — cannot run through esh"
        case .unknown: return "Unknown — not enough metadata to judge"
        }
    }
}

/// Result of a pre-download fit assessment.
public struct ModelFitAssessment: Codable, Sendable, Equatable {
    public var fitClass: ModelFitClass
    public var estimatedPeakMemoryGB: Double?
    public var usableMemoryGB: Double?
    public var totalMemoryGB: Double?
    public var diskRequiredGB: Double?
    public var diskFreeGB: Double?
    public var diskSufficient: Bool
    public var storageAvailable: Bool
    public var recommendedContext: Int?
    public var expectedOptimization: String?
    /// Memory contribution breakdown in GB (weights, runtime, kv, osReserve, otherResident, tts…).
    public var breakdown: [String: Double]
    public var reasons: [String]
    /// Non-empty only for `unsupported`.
    public var blockers: [String]

    public init(
        fitClass: ModelFitClass,
        estimatedPeakMemoryGB: Double? = nil,
        usableMemoryGB: Double? = nil,
        totalMemoryGB: Double? = nil,
        diskRequiredGB: Double? = nil,
        diskFreeGB: Double? = nil,
        diskSufficient: Bool = true,
        storageAvailable: Bool = true,
        recommendedContext: Int? = nil,
        expectedOptimization: String? = nil,
        breakdown: [String: Double] = [:],
        reasons: [String] = [],
        blockers: [String] = []
    ) {
        self.fitClass = fitClass
        self.estimatedPeakMemoryGB = estimatedPeakMemoryGB
        self.usableMemoryGB = usableMemoryGB
        self.totalMemoryGB = totalMemoryGB
        self.diskRequiredGB = diskRequiredGB
        self.diskFreeGB = diskFreeGB
        self.diskSufficient = diskSufficient
        self.storageAvailable = storageAvailable
        self.recommendedContext = recommendedContext
        self.expectedOptimization = expectedOptimization
        self.breakdown = breakdown
        self.reasons = reasons
        self.blockers = blockers
    }

    public var requiresConfirmation: Bool { fitClass.requiresConfirmation || (!diskSufficient) }
    public var isBlocked: Bool { fitClass.isBlocked || !storageAvailable }
}
