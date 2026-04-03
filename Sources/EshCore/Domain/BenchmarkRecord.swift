import Foundation

public struct BenchmarkMeasurement: Codable, Hashable, Sendable {
    public var artifactID: UUID
    public var cacheMode: CacheMode
    public var buildMilliseconds: Double
    public var loadMilliseconds: Double
    public var artifactBytes: Int64
    public var snapshotBytes: Int64?
    public var metrics: Metrics
    public var responsePreview: String

    public init(
        artifactID: UUID,
        cacheMode: CacheMode,
        buildMilliseconds: Double,
        loadMilliseconds: Double,
        artifactBytes: Int64,
        snapshotBytes: Int64? = nil,
        metrics: Metrics,
        responsePreview: String
    ) {
        self.artifactID = artifactID
        self.cacheMode = cacheMode
        self.buildMilliseconds = buildMilliseconds
        self.loadMilliseconds = loadMilliseconds
        self.artifactBytes = artifactBytes
        self.snapshotBytes = snapshotBytes
        self.metrics = metrics
        self.responsePreview = responsePreview
    }
}

public struct BenchmarkRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var sessionID: UUID
    public var sessionName: String
    public var modelID: String
    public var followupMessage: String
    public var createdAt: Date
    public var raw: BenchmarkMeasurement
    public var turbo: BenchmarkMeasurement

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        sessionName: String,
        modelID: String,
        followupMessage: String,
        createdAt: Date = Date(),
        raw: BenchmarkMeasurement,
        turbo: BenchmarkMeasurement
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.modelID = modelID
        self.followupMessage = followupMessage
        self.createdAt = createdAt
        self.raw = raw
        self.turbo = turbo
    }
}
