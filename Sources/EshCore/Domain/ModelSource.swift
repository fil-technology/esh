import Foundation

public struct ModelSource: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case huggingFace
        case localPath
    }

    public var kind: Kind
    public var reference: String
    public var revision: String?

    public init(kind: Kind, reference: String, revision: String? = nil) {
        self.kind = kind
        self.reference = reference
        self.revision = revision
    }
}
