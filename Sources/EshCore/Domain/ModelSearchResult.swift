import Foundation

public struct ModelSearchResult: Identifiable, Codable, Hashable, Sendable {
    public enum CatalogSource: String, Codable, Hashable, Sendable, CaseIterable {
        case local
        case huggingFace
    }

    public var id: String
    public var source: CatalogSource
    public var modelSource: ModelSource
    public var displayName: String
    public var summary: String?
    public var backend: BackendKind?
    public var sizeBytes: Int64?
    public var tags: [String]
    public var downloads: Int?
    public var likes: Int?
    public var isInstalled: Bool
    public var installedModelID: String?
    public var installPath: String?

    public init(
        id: String,
        source: CatalogSource,
        modelSource: ModelSource,
        displayName: String,
        summary: String? = nil,
        backend: BackendKind? = nil,
        sizeBytes: Int64? = nil,
        tags: [String] = [],
        downloads: Int? = nil,
        likes: Int? = nil,
        isInstalled: Bool = false,
        installedModelID: String? = nil,
        installPath: String? = nil
    ) {
        self.id = id
        self.source = source
        self.modelSource = modelSource
        self.displayName = displayName
        self.summary = summary
        self.backend = backend
        self.sizeBytes = sizeBytes
        self.tags = tags
        self.downloads = downloads
        self.likes = likes
        self.isInstalled = isInstalled
        self.installedModelID = installedModelID
        self.installPath = installPath
    }
}
