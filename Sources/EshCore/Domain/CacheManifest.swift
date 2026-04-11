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
    public var contextPackageID: UUID?
    public var contextTask: String?
    public var contextTaskFingerprint: String?
    public var contextFileCount: Int?
    public var contextReused: Bool?
    public var policyReason: String?

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
        sessionName: String,
        contextPackageID: UUID? = nil,
        contextTask: String? = nil,
        contextTaskFingerprint: String? = nil,
        contextFileCount: Int? = nil,
        contextReused: Bool? = nil,
        policyReason: String? = nil
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
        self.contextPackageID = contextPackageID
        self.contextTask = contextTask
        self.contextTaskFingerprint = contextTaskFingerprint
        self.contextFileCount = contextFileCount
        self.contextReused = contextReused
        self.policyReason = policyReason
    }
}
