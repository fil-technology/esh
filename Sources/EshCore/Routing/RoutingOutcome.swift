import Foundation

// esh 2.1 — routing outcomes + install requirements (spec 86eyucfbu §8/§9/§10). After the router PROPOSES
// a CapabilityIntent, esh validates it independently (the router is never the authority) and produces one
// of these distinct outcomes. A missing provider/model is a first-class InstallRequirement, not a generic
// failure — enabling Install-and-Resume.

public struct InstallRequirement: Codable, Sendable, Equatable {
    public var capability: CapabilityID
    public var componentName: String        // user-facing, e.g. "Real-ESRGAN"
    public var recommendedRepo: String      // HF repo id or provider component id
    public var approxSizeMB: Int?
    public var fit: ModelFitAssessment?     // Model Fit when computable (Comfortable/Fits/Tight/…)
    public var everythingLocal: Bool
    /// How to install: "model" → esh model install (POST /v1/models/install); "asset" → the provider's
    /// bridge fetches the component on first execution (explicit via the install card, never silent).
    public var installKind: String
    public init(capability: CapabilityID, componentName: String, recommendedRepo: String,
                approxSizeMB: Int? = nil, fit: ModelFitAssessment? = nil, everythingLocal: Bool = true,
                installKind: String = "model") {
        self.capability = capability
        self.componentName = componentName
        self.recommendedRepo = recommendedRepo
        self.approxSizeMB = approxSizeMB
        self.fit = fit
        self.everythingLocal = everythingLocal
        self.installKind = installKind
    }
}

/// The distinct states the resolver must represent (spec §9).
public enum RoutingOutcome: Sendable {
    case chat                                                   // ordinary conversation
    case ready(ExecutionRequest, CapabilityIntent)             // validated → execute now
    case installRequired(ExecutionRequest, CapabilityIntent, InstallRequirement)  // supported, component missing
    case clarify(reason: String, alternatives: [CapabilityID]) // ambiguous — ask
    case unsupported(reason: String)                           // esh can't do this / agent-layer

    public var isReady: Bool { if case .ready = self { return true }; return false }
}

/// What a capability needs installed before it can run, and how to detect its presence. Data-driven so the
/// resolver stays small. Presence checks are on-disk (models live under the configured assets root).
public struct CapabilityRequirement: Sendable {
    public enum Kind: Sendable {
        case visionModel                         // any installed model with image-understanding (resolver-checked)
        case assetFile(relativePath: String)     // a file under the assets caches root (e.g. an ONNX weight)
    }
    public let capability: CapabilityID
    public let kind: Kind
    public let componentName: String
    public let recommendedRepo: String
    public let approxSizeMB: Int?
}

public enum CapabilityRequirementCatalog {
    /// The recommended local component per capability (for install-and-resume). Capabilities not listed are
    /// treated as self-contained (their provider fetches what it needs) or need no model.
    public static let requirements: [CapabilityID: CapabilityRequirement] = [
        .imageUpscale: .init(capability: .imageUpscale, kind: .assetFile(relativePath: "upscale-models/real_esrgan_x4.onnx"),
                             componentName: "Real-ESRGAN", recommendedRepo: "SceneWorks/real-esrgan-onnx", approxSizeMB: 64),
        .imageUnderstand: .init(capability: .imageUnderstand, kind: .visionModel,
                                componentName: "nanoLLaVA (vision)", recommendedRepo: "mlx-community/nanoLLaVA-1.5-4bit", approxSizeMB: 610),
        .videoUnderstand: .init(capability: .videoUnderstand, kind: .visionModel,
                                componentName: "nanoLLaVA (vision)", recommendedRepo: "mlx-community/nanoLLaVA-1.5-4bit", approxSizeMB: 610),
        .imageGenerate: .init(capability: .imageGenerate, kind: .assetFile(relativePath: "image-models/hub/models--filipstrand--Z-Image-Turbo-mflux-4bit"),
                              componentName: "Z-Image Turbo (4-bit)", recommendedRepo: "filipstrand/Z-Image-Turbo-mflux-4bit", approxSizeMB: 6500),
        // image.edit default backend = FLUX.2 Klein 4B (Apache-2.0, commercial-safe) — the universal fit:
        // ~5GB peak at 4-bit so it runs on a 32GB Mac, where Qwen-Image-Edit (~25-27GB weights) does not.
        // mflux fetches the weights and quantizes to 4-bit at load; size surfaced honestly via Model Fit.
        // A >32GB machine can opt into the higher-fidelity `qwen-edit` backend explicitly.
        .imageEdit: .init(capability: .imageEdit, kind: .assetFile(relativePath: "image-models/hub/models--black-forest-labs--FLUX.2-klein-4B"),
                          componentName: "FLUX.2 Klein 4B (Apache-2.0)", recommendedRepo: "black-forest-labs/FLUX.2-klein-4B", approxSizeMB: 24000),
        .audioDiarize: .init(capability: .audioDiarize, kind: .assetFile(relativePath: "diarization-models/segmentation.onnx"),
                             componentName: "sherpa-onnx diarization", recommendedRepo: "sherpa-onnx speaker models", approxSizeMB: 45),
        // audio.generate NEURAL SFX (deterministic noise/tones are gated out in IntentResolver): AudioGen via
        // the isolated audio runtime. music.generate: MusicGen. Both download to the SSD audio-models cache.
        // approxSizeMB is WEIGHTS/STORAGE footprint (measured on-disk), distinct from peak RUNTIME memory (the
        // bridge's free-RAM floors: SFX 6000 MB, music 2500 MB) and PERFORMANCE (SFX gen RTF ~5.6–6.3×, music
        // ~1.4–1.9×). AudioGen 3.6 GB matches measured; MusicGen's on-disk cache is ~2.2 GB (weights + T5 text
        // encoder + EnCodec, fp32), not the ~1.2 GB the raw model card implies — corrected to measured evidence.
        .audioGenerate: .init(capability: .audioGenerate, kind: .assetFile(relativePath: "audio-models/hub/models--facebook--audiogen-medium"),
                              componentName: "AudioGen (SFX, isolated runtime)", recommendedRepo: "facebook/audiogen-medium", approxSizeMB: 3600),
        .musicGenerate: .init(capability: .musicGenerate, kind: .assetFile(relativePath: "audio-models/hub/models--facebook--musicgen-small"),
                              componentName: "MusicGen (CC-BY-NC)", recommendedRepo: "facebook/musicgen-small", approxSizeMB: 2200),
    ]
}
