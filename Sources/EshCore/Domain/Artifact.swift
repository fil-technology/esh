import Foundation

// esh 2.1 UCMR, Stage 0 — first-class typed Artifact. Binary/media results are represented as Artifacts
// (referenced by id and fetched as bytes), never forced into JSON strings/base64. See docs/UCMR_ARCHITECTURE.md.

public enum ArtifactKind: String, Codable, Hashable, Sendable, CaseIterable {
    case text
    case json
    case image
    case svg
    case audio
    case video
    case document
    case code
    case webProject
    case embedding
    case ranked
    case segmentation
}

/// One file within an artifact bundle (single-file artifacts have exactly one).
public struct ArtifactFile: Codable, Hashable, Sendable {
    public var relativePath: String
    public var byteSize: Int
    public var sha256: String?
    public init(relativePath: String, byteSize: Int, sha256: String? = nil) {
        self.relativePath = relativePath
        self.byteSize = byteSize
        self.sha256 = sha256
    }
}

/// How an artifact was produced (for the Execution Inspector and truthful provenance).
public struct ArtifactProvenance: Codable, Hashable, Sendable {
    public var providerID: String?
    public var modelID: String?
    public var capability: CapabilityID?
    public var executionPlanID: UUID?
    /// The artifact this one was derived FROM (image.edit result → its source image, edit→upscale chains,
    /// iterative "Edit again"). Enables lineage for iterative transforms + Ashex. nil for first-generation.
    public var sourceArtifactID: UUID?
    public init(providerID: String? = nil, modelID: String? = nil, capability: CapabilityID? = nil,
                executionPlanID: UUID? = nil, sourceArtifactID: UUID? = nil) {
        self.providerID = providerID
        self.modelID = modelID
        self.capability = capability
        self.executionPlanID = executionPlanID
        self.sourceArtifactID = sourceArtifactID
    }
}

public struct ArtifactValidation: Codable, Hashable, Sendable {
    public var isValid: Bool
    public var findings: [String]
    public init(isValid: Bool, findings: [String] = []) {
        self.isValid = isValid
        self.findings = findings
    }
    public static let notValidated = ArtifactValidation(isValid: false, findings: ["not validated"])
    public static let valid = ArtifactValidation(isValid: true)
}

/// The least privilege required to preview an artifact (see docs/UCMR_ARCHITECTURE.md §11).
public enum PrivilegeLevel: String, Codable, Hashable, Sendable, CaseIterable, Comparable {
    case artifactOnly = "artifact-only"
    case validated
    case previewSandboxed = "preview-sandboxed"
    case explicitFull = "explicit-full"

    private var order: Int {
        switch self {
        case .artifactOnly: return 0
        case .validated: return 1
        case .previewSandboxed: return 2
        case .explicitFull: return 3
        }
    }
    public static func < (lhs: PrivilegeLevel, rhs: PrivilegeLevel) -> Bool { lhs.order < rhs.order }
}

public struct PreviewDescriptor: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, Hashable, Sendable {
        case none
        case staticSandbox = "static-sandbox"   // WKWebView secure-static / JS-off, no network
        case managed                            // runnable project under isolation (tier-4)
    }
    public var mode: Mode
    public var privilege: PrivilegeLevel
    public init(mode: Mode, privilege: PrivilegeLevel) {
        self.mode = mode
        self.privilege = privilege
    }
    public static let none = PreviewDescriptor(mode: .none, privilege: .artifactOnly)
    public static let staticSandbox = PreviewDescriptor(mode: .staticSandbox, privilege: .artifactOnly)
}

/// A typed result artifact. Persisted in the artifact store and linked to the originating message.
public struct Artifact: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: ArtifactKind
    public var mimeType: String
    public var files: [ArtifactFile]
    public var entrypoint: String?
    public var metadata: [String: JSONValue]
    public var generatedBy: ArtifactProvenance
    public var validation: ArtifactValidation
    public var preview: PreviewDescriptor
    public var createdAt: Date

    public init(id: UUID = UUID(),
                kind: ArtifactKind,
                mimeType: String,
                files: [ArtifactFile] = [],
                entrypoint: String? = nil,
                metadata: [String: JSONValue] = [:],
                generatedBy: ArtifactProvenance = .init(),
                validation: ArtifactValidation = .notValidated,
                preview: PreviewDescriptor = .none,
                createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.mimeType = mimeType
        self.files = files
        self.entrypoint = entrypoint
        self.metadata = metadata
        self.generatedBy = generatedBy
        self.validation = validation
        self.preview = preview
        self.createdAt = createdAt
    }

    public var totalByteSize: Int { files.reduce(0) { $0 + $1.byteSize } }
}

/// A resolved artifact file's bytes for serving over HTTP (GET /v1/artifacts/{id}[/{file}]).
public struct ArtifactBytes: Sendable {
    public var data: Data
    public var mimeType: String
    public var filename: String
    public init(data: Data, mimeType: String, filename: String) {
        self.data = data
        self.mimeType = mimeType
        self.filename = filename
    }
}
