import Foundation

public struct RecommendedModel: Identifiable, Codable, Hashable, Sendable {
    public enum Profile: String, Codable, Hashable, Sendable, CaseIterable {
        case chat
        case code
    }

    public enum Tier: String, Codable, Hashable, Sendable, CaseIterable {
        case fast
        case balanced
        case quality
    }

    public var id: String
    public var title: String
    public var repoID: String
    public var profile: Profile
    public var tier: Tier
    public var memoryHint: String
    public var sizeHint: String
    public var summary: String
    public var backend: BackendKind

    public init(
        id: String,
        title: String,
        repoID: String,
        profile: Profile,
        tier: Tier,
        memoryHint: String,
        sizeHint: String,
        summary: String,
        backend: BackendKind = .mlx
    ) {
        self.id = id
        self.title = title
        self.repoID = repoID
        self.profile = profile
        self.tier = tier
        self.memoryHint = memoryHint
        self.sizeHint = sizeHint
        self.summary = summary
        self.backend = backend
    }
}
