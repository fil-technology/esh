import Foundation

// HF integration — public domain types (HF1). Built on the existing `ModelSource` reference + `ModelMetadata`
// inspection + `ModelFitAssessment`. Studio consumes these; it never learns Hugging Face internals.

/// Parses the many ways a user/app names a Hugging Face repo into the stable `ModelSource` reference.
public enum HuggingFaceReference {
    /// Accepts: "owner/repo", "https://huggingface.co/owner/repo", ".../owner/repo/tree/<rev>",
    /// ".../owner/repo/blob/<rev>/<file>", ".../resolve/<rev>/<file>", and "owner/repo@revision".
    /// Returns nil when the string can't be resolved to a repo id.
    public static func parse(_ raw: String) -> ModelSource? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // URL form.
        if let url = URL(string: s), let host = url.host, host.contains("huggingface.co") {
            var parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
            // Optional leading "models" segment: huggingface.co/models/owner/repo
            if parts.first == "models" { parts.removeFirst() }
            guard parts.count >= 2 else { return nil }
            let owner = parts[0], repo = parts[1]
            var revision: String?
            // tree/<rev>, blob/<rev>/..., resolve/<rev>/...
            if parts.count >= 4, ["tree", "blob", "resolve"].contains(parts[2]) {
                revision = parts[3]
            }
            return ModelSource(kind: .huggingFace, reference: "\(owner)/\(repo)", revision: revision)
        }

        // "owner/repo@revision"
        var revision: String?
        if let at = s.lastIndex(of: "@") {
            let rev = String(s[s.index(after: at)...])
            let base = String(s[..<at])
            // Only treat as revision if the base still looks like owner/repo.
            if base.split(separator: "/").count == 2, !rev.isEmpty {
                revision = rev; s = base
            }
        }

        // "owner/repo" (exactly two path components, no scheme).
        let comps = s.split(separator: "/").map(String.init)
        guard comps.count == 2, !comps[0].isEmpty, !comps[1].isEmpty,
              !comps[0].contains(":"), !s.contains(" ") else { return nil }
        return ModelSource(kind: .huggingFace, reference: "\(comps[0])/\(comps[1])", revision: revision)
    }

    /// Canonical model-card URL for a repo (for "Review license" / "Open on Hugging Face").
    public static func modelCardURL(_ source: ModelSource) -> URL? {
        URL(string: "https://huggingface.co/\(source.reference)")
    }
}

/// Hugging Face account state — never carries the raw token.
public enum HFAccountState: Sendable, Equatable {
    case disconnected
    case connected(username: String?)
    case tokenInvalid
}

/// Normalized access state for a repo. HF remains the authority; web-required steps expose an `actionURL`.
public enum ModelAccessStatus: Sendable, Equatable {
    case publicAccess
    case authenticationRequired
    case gatedTermsRequired(actionURL: URL?)
    case accessRequestPending
    case accessDenied
    case privateAuthorized
    case privateUnauthorized
    case notFound
}

/// esh's source-compatibility verdict — distinct from Model Fit (which is device headroom).
public enum SourceCompatibility: Sendable, Equatable {
    case verified                    // known arch + layout + a tested runtime recipe
    case compatible                  // recognized arch/files + a supported runtime, not in the curated set
    case experimental(reason: String)
    case unsupported(reason: String)
    case unknown(reason: String)
}

/// Normalized, truthful license metadata. Never infers "commercial-safe".
public struct HFLicenseInfo: Sendable, Equatable, Codable {
    public var identifier: String?       // e.g. "apache-2.0"; nil == not specified
    public var name: String?             // human name when known
    public var url: URL?                 // license file/page when known
    public var modelCardURL: URL?
    public init(identifier: String? = nil, name: String? = nil, url: URL? = nil, modelCardURL: URL? = nil) {
        self.identifier = identifier; self.name = name; self.url = url; self.modelCardURL = modelCardURL
    }
    public static let unknown = HFLicenseInfo()
}

/// One installable artifact/quantization for a repo (e.g. a GGUF quant), with its own Model Fit.
public struct ModelArtifactCandidate: Sendable, Equatable, Identifiable {
    public var id: String                // stable within a repo (variant or primary filename)
    public var variant: String?          // e.g. "Q4_K_M"; nil for single-artifact MLX layouts
    public var format: ModelFormat
    public var backend: BackendKind?
    public var primaryFile: String?
    public var companionFiles: [String]
    public var sizeBytes: Int64?
    public var fit: ModelFitAssessment?
    public var isRecommended: Bool
    public init(id: String, variant: String? = nil, format: ModelFormat, backend: BackendKind? = nil,
                primaryFile: String? = nil, companionFiles: [String] = [], sizeBytes: Int64? = nil,
                fit: ModelFitAssessment? = nil, isRecommended: Bool = false) {
        self.id = id; self.variant = variant; self.format = format; self.backend = backend
        self.primaryFile = primaryFile; self.companionFiles = companionFiles; self.sizeBytes = sizeBytes
        self.fit = fit; self.isRecommended = isRecommended
    }
}

/// The resolved view of a repo: metadata + access + license + compatibility. What Studio renders on details.
public struct ModelSourceRecord: Sendable {
    public var source: ModelSource
    public var metadata: ModelMetadata
    public var access: ModelAccessStatus
    public var compatibility: SourceCompatibility
    public var license: HFLicenseInfo
    public var gated: Bool
    public init(source: ModelSource, metadata: ModelMetadata, access: ModelAccessStatus,
                compatibility: SourceCompatibility, license: HFLicenseInfo, gated: Bool) {
        self.source = source; self.metadata = metadata; self.access = access
        self.compatibility = compatibility; self.license = license; self.gated = gated
    }
}

/// Typed HF errors for Studio UX (never raw network/stack traces at the boundary).
public enum HuggingFaceError: Error, LocalizedError, Equatable {
    case invalidReference(String)
    case authenticationRequired
    case gatedTermsRequired(actionURL: URL?)
    case accessDenied
    case repositoryNotFound
    case unsupportedArchitecture(String)
    case unsupportedFormat(String)
    case noCompatibleArtifact
    case insufficientResources
    case insufficientDisk
    case checksumMismatch
    case networkFailure(String)
    case tokenInvalid
    case licenseMetadataUnavailable

    public var errorDescription: String? {
        switch self {
        case let .invalidReference(r): return "Not a valid Hugging Face reference: \(r)"
        case .authenticationRequired: return "This model requires signing in to Hugging Face."
        case .gatedTermsRequired: return "This model requires accepting its terms on Hugging Face."
        case .accessDenied: return "This Hugging Face account does not have access to this model."
        case .repositoryNotFound: return "This Hugging Face repository was not found."
        case let .unsupportedArchitecture(a): return "Unsupported architecture: \(a)"
        case let .unsupportedFormat(f): return "Unsupported format: \(f)"
        case .noCompatibleArtifact: return "No artifact in this repository can run on this device."
        case .insufficientResources: return "This model needs more memory than is safely available."
        case .insufficientDisk: return "Not enough free disk space to install this model."
        case .checksumMismatch: return "A downloaded file failed integrity verification."
        case let .networkFailure(m): return "Network error: \(m)"
        case .tokenInvalid: return "The Hugging Face token is invalid or expired."
        case .licenseMetadataUnavailable: return "License information is unavailable for this model."
        }
    }
}
