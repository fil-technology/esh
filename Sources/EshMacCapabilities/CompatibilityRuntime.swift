import Foundation
import EshCore
import EshRuntime

// esh v2.4 — the esh-owned macOS compatibility runtime contracts.
//
// These types let esh expose existing macOS-only (Python/MLX-backed) capabilities — music, SFX, advanced
// image editing, diarization — through the SAME public capability facade, with esh owning the whole
// lifecycle (inspect → install → repair → health → execute). A consumer (Esh Studio) never learns that
// Python, venvs, pip, subprocesses, or bridge scripts exist: it only sees capability discovery, execute/
// stream, typed artifacts, and honest availability states. The actual execution/bootstrap is behind the
// injectable `CompatibilityEngineHost` seam, so the state machine + facade integration are fully testable
// with a mock, and the concrete macOS Python host plugs into the same seam.

/// The engines the compatibility runtime can manage. `rawValue` matches esh's engine ids.
public enum CompatibilityEngineID: String, Sendable, Hashable, CaseIterable, Codable {
    case music              = "music"
    case soundFX            = "sound-fx"
    case advancedImageEdit  = "advanced-image-edit"
    case diarization        = "diarization"
}

/// A required Python module and the pip package that provides it. Preflight probes `module`; a missing one
/// is the honest, repairable failure (this is where the `soundfile` case is caught before a raw traceback).
public struct CompatibilityModule: Sendable, Hashable, Codable {
    public let module: String
    public let pipPackage: String
    public init(module: String, pipPackage: String) { self.module = module; self.pipPackage = pipPackage }
}

/// A model asset an engine needs, described in esh's own catalog terms (never a Python path to the consumer).
public struct CompatibilityModelAsset: Sendable, Hashable, Codable {
    public let id: String
    public let displayName: String
    public let approxBytes: Int64?
    public let sha256: String?
    public init(id: String, displayName: String, approxBytes: Int64? = nil, sha256: String? = nil) {
        self.id = id; self.displayName = displayName; self.approxBytes = approxBytes; self.sha256 = sha256
    }
}

/// The declared runtime manifest for one compatibility engine (§4). One coherent place owns an engine's
/// dependencies + assets instead of scattering arrays across the codebase.
public struct CompatibilityEngineManifest: Sendable, Hashable, Codable {
    public let id: CompatibilityEngineID
    public let version: String
    public let capabilities: [CapabilityID]
    public let acceptedInputs: [ModelModality]
    public let producedOutputs: [ModelModality]
    public let producedArtifactKind: ArtifactKind
    public let runtimeVersion: String
    public let minimumOS: String
    public let requiredModules: [CompatibilityModule]
    public let modelAssets: [CompatibilityModelAsset]

    public init(id: CompatibilityEngineID, version: String, capabilities: [CapabilityID],
                acceptedInputs: [ModelModality], producedOutputs: [ModelModality],
                producedArtifactKind: ArtifactKind, runtimeVersion: String, minimumOS: String,
                requiredModules: [CompatibilityModule], modelAssets: [CompatibilityModelAsset]) {
        self.id = id; self.version = version; self.capabilities = capabilities
        self.acceptedInputs = acceptedInputs; self.producedOutputs = producedOutputs
        self.producedArtifactKind = producedArtifactKind; self.runtimeVersion = runtimeVersion
        self.minimumOS = minimumOS; self.requiredModules = requiredModules; self.modelAssets = modelAssets
    }

    /// Total declared download footprint (dependencies aren't sized here; models are).
    public var approxDownloadBytes: Int64? {
        let sizes = modelAssets.compactMap { $0.approxBytes }
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }
}

/// Live engine state esh computes via preflight. Distinct, product-relevant states — never "venv missing".
public enum CompatibilityEngineState: Sendable, Equatable {
    case notInstalled
    case requiresDownload(bytes: Int64?)
    case installing(progress: Double)
    case repairRequired(reason: String)
    case ready
    case unsupportedOnPlatform
    case failed(reason: String)

    /// Map an engine state to the public capability-availability the SDK reports (§8).
    public var availability: CapabilityAvailability {
        switch self {
        case .notInstalled:                 return .requiresDownload(modelID: nil, bytes: nil)
        case .requiresDownload(let bytes):  return .requiresDownload(modelID: nil, bytes: bytes)
        case .installing(let p):            return .installing(progress: p)
        case .repairRequired(let r):        return .repairRequired(reason: r)
        case .ready:                        return .ready
        case .unsupportedOnPlatform:        return .unsupportedOnPlatform
        case .failed(let r):                return .failed(reason: r)
        }
    }
}

/// Typed errors surfaced to consumers (§9). No raw Python traceback ever reaches this surface; technical
/// detail is preserved separately for diagnostics.
public enum CompatibilityError: Error, LocalizedError, Equatable, Sendable {
    case engineNotInstalled(CompatibilityEngineID)
    case engineRepairRequired(CompatibilityEngineID, reason: String)
    case runtimeUnavailable(reason: String)
    case dependencyInstallationFailed(reason: String)
    case modelMissing(String)
    case modelVerificationFailed(String)
    case executionFailed(reason: String)
    case cancelled
    case unsupportedOnPlatform

    public var errorDescription: String? {
        switch self {
        case .engineNotInstalled(let id): return "The \(id.rawValue) engine is not installed."
        case .engineRepairRequired(let id, let r): return "The \(id.rawValue) engine needs repair: \(r)"
        case .runtimeUnavailable(let r): return "The runtime is unavailable: \(r)"
        case .dependencyInstallationFailed(let r): return "Installing engine dependencies failed: \(r)"
        case .modelMissing(let id): return "Required model '\(id)' is not installed."
        case .modelVerificationFailed(let id): return "Model '\(id)' failed verification."
        case .executionFailed(let r): return "Generation failed: \(r)"
        case .cancelled: return "The operation was cancelled."
        case .unsupportedOnPlatform: return "This capability is not supported on this platform."
        }
    }
}

/// The injectable seam esh owns beneath the compatibility provider. A concrete macOS conformer manages the
/// real Python runtime/venv/subprocess; tests inject a deterministic mock. It NEVER surfaces Python details
/// through its API — only states, typed errors, and capability events/artifacts.
public protocol CompatibilityEngineHost: Sendable {
    /// Cheap health/preflight: is the engine installed, does its runtime validate, are all required modules
    /// and models present? This is where a missing module (e.g. `soundfile`) becomes `.repairRequired`.
    func inspect(_ manifest: CompatibilityEngineManifest) async -> CompatibilityEngineState
    /// Clean bootstrap: provision the runtime, install declared dependencies, fetch/verify model assets.
    func install(_ manifest: CompatibilityEngineManifest, onProgress: @Sendable @escaping (Double) -> Void) async throws
    /// Repair a present-but-broken engine (reinstall missing/corrupt dependencies) without a full wipe.
    func repair(_ manifest: CompatibilityEngineManifest) async throws
    /// Execute the engine's capability, streaming events + producing a typed artifact. esh owns the
    /// subprocess; cancelling the returned stream must terminate it and leave no orphan.
    func run(_ manifest: CompatibilityEngineManifest, _ request: ResolvedExecutionRequest,
             context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error>
}
