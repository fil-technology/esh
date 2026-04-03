import Foundation

public struct RecommendedModel: Identifiable, Codable, Hashable, Sendable {
    public enum Profile: String, Codable, Hashable, Sendable, CaseIterable {
        case chat
        case code
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
    public var sortOrder: Int

    public var memoryHint: String {
        "\(Self.formatGigabytes(estimatedMemoryGB)) GB+"
    }

    public var sizeHint: String {
        "~\(Self.formatGigabytes(totalDiskSizeGB)) GB"
    }

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
        self.sortOrder = sortOrder
    }

    private static func formatGigabytes(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}
