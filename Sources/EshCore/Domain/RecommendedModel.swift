import Foundation

public struct RecommendedModel: Identifiable, Codable, Hashable, Sendable {
    public enum Profile: String, Codable, Hashable, Sendable, CaseIterable {
        case chat
        case code
    }

    /// Structured capabilities a model is known to support well. Kept as an explicit list on each
    /// catalog entry (rather than heuristically guessed from the name) so recommendations and
    /// filtering are reliable. See ModelFeatureClassifier for the display-badge heuristics.
    public enum Capability: String, Codable, Hashable, Sendable, CaseIterable {
        case chat
        case coding
        case reasoning
        case toolCalling = "tool-calling"
        case vision
    }

    /// Lifecycle status of a catalog entry, so obsolete entries are deprecated rather than
    /// silently broken.
    public enum Status: String, Codable, Hashable, Sendable, CaseIterable {
        case recommended     // verified current + compatible
        case experimental    // works but newer/less-proven runtime or template
        case legacy          // superseded; kept for compatibility
        case incompatible    // known not to run through esh's current runtimes
    }

    public enum Tier: String, Codable, Hashable, Sendable, CaseIterable {
        case good
        case small
        case tiny
        case max

        public var displayName: String {
            switch self {
            case .good:
                "Good (The Sweet Spot)"
            case .small:
                "Small (High Efficiency)"
            case .tiny:
                "Tiny (Ultra Lightweight)"
            case .max:
                "Max (Pushing 32GB Mac Limits)"
            }
        }

        public var sortRank: Int {
            switch self {
            case .good: 0
            case .small: 1
            case .tiny: 2
            case .max: 3
            }
        }
    }

    public var id: String
    public var title: String
    public var repoID: String
    public var parameterSize: String
    public var quantization: String
    public var profile: Profile
    public var tier: Tier
    public var estimatedMemoryGB: Double
    public var totalDiskSizeGB: Double
    public var tags: [String]
    public var summary: String
    public var backend: BackendKind
    public var contextWindow: Int?
    public var capabilities: [Capability]
    public var status: Status
    public var sortOrder: Int

    public var memoryHint: String {
        "\(Self.formatGigabytes(estimatedMemoryGB)) GB+"
    }

    public var sizeHint: String {
        "~\(Self.formatGigabytes(totalDiskSizeGB)) GB"
    }

    /// Human-friendly context window, e.g. "256K", "128K", "32K", or "-" when unknown.
    public var contextHint: String {
        guard let contextWindow else { return "-" }
        if contextWindow >= 1024, contextWindow % 1024 == 0 {
            return "\(contextWindow / 1024)K"
        }
        if contextWindow >= 1000 {
            return "\(contextWindow / 1000)K"
        }
        return "\(contextWindow)"
    }

    public var supportsToolCalling: Bool { capabilities.contains(.toolCalling) }

    public init(
        id: String,
        title: String,
        repoID: String,
        parameterSize: String,
        quantization: String,
        profile: Profile,
        tier: Tier,
        estimatedMemoryGB: Double,
        totalDiskSizeGB: Double,
        tags: [String],
        summary: String,
        backend: BackendKind = .mlx,
        contextWindow: Int? = nil,
        capabilities: [Capability] = [],
        status: Status = .recommended,
        sortOrder: Int
    ) {
        self.id = id
        self.title = title
        self.repoID = repoID
        self.parameterSize = parameterSize
        self.quantization = quantization
        self.profile = profile
        self.tier = tier
        self.estimatedMemoryGB = estimatedMemoryGB
        self.totalDiskSizeGB = totalDiskSizeGB
        self.tags = tags
        self.summary = summary
        self.backend = backend
        self.contextWindow = contextWindow
        self.capabilities = capabilities
        self.status = status
        self.sortOrder = sortOrder
    }

    private static func formatGigabytes(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}
