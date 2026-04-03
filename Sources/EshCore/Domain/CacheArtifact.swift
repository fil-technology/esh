import Foundation

public struct CacheArtifact: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var manifest: CacheManifest
    public var artifactPath: String
    public var snapshotPath: String?
    public var sizeBytes: Int64
    public var snapshotSizeBytes: Int64?
    public var metrics: Metrics

    public init(
        id: UUID = UUID(),
        manifest: CacheManifest,
        artifactPath: String,
        snapshotPath: String? = nil,
        sizeBytes: Int64,
        snapshotSizeBytes: Int64? = nil,
        metrics: Metrics = Metrics()
    ) {
        self.id = id
        self.manifest = manifest
        self.artifactPath = artifactPath
        self.snapshotPath = snapshotPath
        self.sizeBytes = sizeBytes
        self.snapshotSizeBytes = snapshotSizeBytes
        self.metrics = metrics
    }
}
