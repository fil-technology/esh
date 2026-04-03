import Foundation

public struct CacheManifest: Codable, Hashable, Sendable {
    public var backend: BackendKind
    public var modelID: String
    public var tokenizerID: String?
    public var architectureFingerprint: String
    public var runtimeVersion: String
    public var cacheFormatVersion: String
    public var compressorVersion: String?
    public var cacheMode: CacheMode
    public var createdAt: Date
    public var sessionID: UUID
    public var sessionName: String

    public init(
        backend: BackendKind,
        modelID: String,
        tokenizerID: String? = nil,
        architectureFingerprint: String,
        runtimeVersion: String,
        cacheFormatVersion: String,
        compressorVersion: String? = nil,
        cacheMode: CacheMode,
        createdAt: Date = Date(),
        sessionID: UUID,
        sessionName: String
    ) {
        self.backend = backend
        self.modelID = modelID
        self.tokenizerID = tokenizerID
        self.architectureFingerprint = architectureFingerprint
        self.runtimeVersion = runtimeVersion
        self.cacheFormatVersion = cacheFormatVersion
        self.compressorVersion = compressorVersion
        self.cacheMode = cacheMode
        self.createdAt = createdAt
        self.sessionID = sessionID
        self.sessionName = sessionName
    }
}
