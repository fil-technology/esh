import Foundation

public struct ContextPackageFile: Codable, Hashable, Sendable {
    public let path: String
    public let contentHash: String

    public init(path: String, contentHash: String) {
        self.path = path
        self.contentHash = contentHash
    }
}

public struct ContextPackageManifest: Codable, Hashable, Sendable {
    public let createdAt: Date
    public let workspaceRootPath: String
    public let task: String
    public let taskFingerprint: String
    public let modelID: String?
    public let intent: SessionIntent?
    public let cacheMode: CacheMode?
    public let files: [ContextPackageFile]

    public init(
        createdAt: Date = Date(),
        workspaceRootPath: String,
        task: String,
        taskFingerprint: String,
        modelID: String? = nil,
        intent: SessionIntent? = nil,
        cacheMode: CacheMode? = nil,
        files: [ContextPackageFile]
    ) {
        self.createdAt = createdAt
        self.workspaceRootPath = workspaceRootPath
        self.task = task
        self.taskFingerprint = taskFingerprint
        self.modelID = modelID
        self.intent = intent
        self.cacheMode = cacheMode
        self.files = files
    }
}

public struct ContextPackage: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var manifest: ContextPackageManifest
    public var packagePath: String
    public var sizeBytes: Int64
    public var brief: ContextPlanningBrief

    public init(
        id: UUID = UUID(),
        manifest: ContextPackageManifest,
        packagePath: String,
        sizeBytes: Int64,
        brief: ContextPlanningBrief
    ) {
        self.id = id
        self.manifest = manifest
        self.packagePath = packagePath
        self.sizeBytes = sizeBytes
        self.brief = brief
    }
}

public struct ContextPackageResolution: Sendable {
    public let package: ContextPackage
    public let brief: ContextPlanningBrief
    public let reused: Bool

    public init(package: ContextPackage, brief: ContextPlanningBrief, reused: Bool) {
        self.package = package
        self.brief = brief
        self.reused = reused
    }
}
