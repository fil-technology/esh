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
    case imageGeneration    = "image-generation"
    case advancedImageEdit  = "advanced-image-edit"
    case diarization        = "diarization"
    case voiceClone         = "voice-clone"
    case qwenImage21        = "qwen-image-2.1"
}

/// A required Python module and the pip package that provides it. Preflight probes `module`; a missing one
/// is the honest, repairable failure (this is where the `soundfile` case is caught before a raw traceback).
public struct CompatibilityModule: Sendable, Hashable, Codable {
    public let module: String
    public let pipPackage: String
    public init(module: String, pipPackage: String) { self.module = module; self.pipPackage = pipPackage }
}

/// An ISOLATED interpreter an engine's heavy runtime lives in, kept OUT of the shared MLX venv because its
/// dependency pins would destabilize it (voice-clone needs `torch<2.9` / `transformers<5`; AudioGen needs the
/// `mlx-audiocraft` stack). When present, esh provisions a dedicated venv, installs/probes `modules` THERE,
/// and points the bridge at it via `envVar` at run time. The manifest's top-level `requiredModules` remain the
/// SHARED bridge dependencies, always probed against the main managed venv (the bridge itself runs there).
public struct IsolatedRuntime: Sendable, Hashable, Codable {
    /// Venv directory name under the managed audio-assets root (e.g. `voiceclone-venv`).
    public let dirName: String
    /// The environment variable the bridge reads to locate this interpreter (e.g. `ESH_VOICECLONE_PYTHON`).
    public let envVar: String
    /// The Python modules this isolated runtime requires, probed/installed against the isolated venv only.
    public let modules: [CompatibilityModule]
    public init(dirName: String, envVar: String, modules: [CompatibilityModule]) {
        self.dirName = dirName; self.envVar = envVar; self.modules = modules
    }
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
    /// An optional isolated interpreter this engine's heavy runtime lives in (see `IsolatedRuntime`). `nil` for
    /// engines that run entirely in the shared managed venv (music, diarization, image generation/edit).
    public let isolatedRuntime: IsolatedRuntime?
    /// SPDX-style license identifier of the engine's weights (e.g. `apache-2.0`, `LicenseRef-Qwen-Research`).
    /// Surfaced truthfully to consumers + persisted in artifact provenance. `nil` = unspecified/permissive.
    public let licenseIdentifier: String?
    /// Whether the weights may be used commercially. `false` = research/non-commercial only — esh keeps such
    /// an engine out of Auto defaults (pin-only) so it can't silently become a commercial-production default.
    public let commercialUse: Bool
    /// esh-owned resource facts (peak memory, download/install bytes, per-volume headroom) — drives
    /// resource-aware Auto ranking + execution-time fit gating. `nil` keeps legacy native-first selection.
    public let resourceProfile: CapabilityResourceProfile?

    public init(id: CompatibilityEngineID, version: String, capabilities: [CapabilityID],
                acceptedInputs: [ModelModality], producedOutputs: [ModelModality],
                producedArtifactKind: ArtifactKind, runtimeVersion: String, minimumOS: String,
                requiredModules: [CompatibilityModule], modelAssets: [CompatibilityModelAsset],
                isolatedRuntime: IsolatedRuntime? = nil,
                licenseIdentifier: String? = nil, commercialUse: Bool = true,
                resourceProfile: CapabilityResourceProfile? = nil) {
        self.id = id; self.version = version; self.capabilities = capabilities
        self.acceptedInputs = acceptedInputs; self.producedOutputs = producedOutputs
        self.producedArtifactKind = producedArtifactKind; self.runtimeVersion = runtimeVersion
        self.minimumOS = minimumOS; self.requiredModules = requiredModules; self.modelAssets = modelAssets
        self.isolatedRuntime = isolatedRuntime
        self.licenseIdentifier = licenseIdentifier; self.commercialUse = commercialUse
        self.resourceProfile = resourceProfile
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
    /// Installed/installable, but this device's current state (free disk for swap, memory) can't run the
    /// model safely right now. Transient by nature — freeing resources restores it — so it maps to
    /// `.temporarilyUnavailable`, not a hard `.unsupportedOnDevice`.
    case insufficientResources(reason: String)

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
        case .insufficientResources(let r): return .temporarilyUnavailable(reason: r)
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
    /// This device's current resource state can't run the model safely (e.g. too little free disk for swap).
    /// Honest, non-crashing alternative to letting the run drive the machine into swap exhaustion.
    case insufficientResources(reason: String)

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
        case .insufficientResources(let r): return "Insufficient resources to run safely: \(r)"
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
