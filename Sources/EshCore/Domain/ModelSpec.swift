import Foundation

public struct ModelSpec: Codable, Hashable, Sendable {
    public var id: String
    public var displayName: String
    public var backend: BackendKind
    public var source: ModelSource
    public var localPath: String?
    public var tokenizerID: String?
    public var architectureFingerprint: String?
    public var variant: String?

    public init(
        id: String,
        displayName: String,
        backend: BackendKind,
        source: ModelSource,
        localPath: String? = nil,
        tokenizerID: String? = nil,
        architectureFingerprint: String? = nil,
        variant: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.backend = backend
        self.source = source
        self.localPath = localPath
        self.tokenizerID = tokenizerID
        self.architectureFingerprint = architectureFingerprint
        self.variant = variant
    }
}
