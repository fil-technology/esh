import Foundation

/// Traceability for a model installed from Hugging Face (HF6 provenance). Never carries credentials.
/// Optional on `ModelInstall`; nil for curated/local installs. Codable-tolerant (missing key → nil).
public struct HuggingFaceInstallProvenance: Codable, Hashable, Sendable {
    public var repoID: String
    public var revision: String?          // commit SHA preferred for immutability
    public var files: [String]
    public var format: String
    public var quantization: String?
    public var licenseIdentifier: String?
    public var gated: Bool
    public var isPrivate: Bool
    public init(repoID: String, revision: String? = nil, files: [String] = [], format: String,
                quantization: String? = nil, licenseIdentifier: String? = nil,
                gated: Bool = false, isPrivate: Bool = false) {
        self.repoID = repoID; self.revision = revision; self.files = files; self.format = format
        self.quantization = quantization; self.licenseIdentifier = licenseIdentifier
        self.gated = gated; self.isPrivate = isPrivate
    }
}

public struct ModelInstall: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var spec: ModelSpec
    public var installPath: String
    public var sizeBytes: Int64
    public var installedAt: Date
    public var backendFormat: String
    public var runtimeVersion: String?
    /// Set when installed from Hugging Face (HF6). nil for curated/local models.
    public var huggingFace: HuggingFaceInstallProvenance?

    public init(
        id: String,
        spec: ModelSpec,
        installPath: String,
        sizeBytes: Int64,
        installedAt: Date = Date(),
        backendFormat: String,
        runtimeVersion: String? = nil,
        huggingFace: HuggingFaceInstallProvenance? = nil
    ) {
        self.id = id
        self.spec = spec
        self.installPath = installPath
        self.sizeBytes = sizeBytes
        self.installedAt = installedAt
        self.backendFormat = backendFormat
        self.runtimeVersion = runtimeVersion
        self.huggingFace = huggingFace
    }
}
