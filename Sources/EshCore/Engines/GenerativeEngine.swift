import Foundation

// esh generative engines — heavy, OPTIONAL local runtimes the user installs on demand, kept out of the base
// install so a fresh esh stays small. Each engine powers one or more capabilities; its Python deps (and, on
// first use, its model weights) are large and land on managed storage (the external SSD when configured).
// esh OWNS install / probe / remove so clients (web UI, Ashex agent) just trigger + track — they never run
// `pip` or touch a venv themselves. This generalizes the existing AudioGen isolated-runtime pattern.
//
// Design note — zero bridge changes: engines install into the venv locations the Python bridge ALREADY
// discovers. CLI-based (mflux) and in-process (torch / onnxruntime / rembg / sherpa-onnx) engines install into
// esh's main managed env (`$ESH_PYTHON`, which the bridge runs as `sys.executable`); the isolated AudioGen
// engine installs into the venv path `_isolated_audiogen_python()` already looks up. Model weights always
// cache under the assets root (SSD) regardless of where the engine's code lives.

/// The set of installable generative engines. Raw values are the stable public ids used by the HTTP API,
/// the web UI, and the agent.
public enum GenerativeEngineID: String, Codable, Hashable, Sendable, CaseIterable {
    case image     = "image"      // mflux: text→image, FLUX.2/Qwen image edit, SeedVR2 upscale
    case soundFX   = "sound-fx"   // AudioGen SFX (mlx-audiocraft) — isolated venv
    case music     = "music"      // MusicGen (torch + transformers)
    case upscale   = "upscale"    // Real-ESRGAN (onnxruntime)
    case removeBG  = "remove-bg"  // background removal (rembg + onnxruntime)
    case diarize   = "diarize"    // speaker diarization (sherpa-onnx)
}

/// Where an engine's Python code is installed. Weights are unaffected (always on the assets root).
public enum EngineVenvTarget: Sendable, Equatable {
    /// esh's main managed Python env (`$ESH_PYTHON`). For CLI-based and in-bridge engines the bridge runs via
    /// `sys.executable`; only the (small-to-medium) deps go here, so nothing needs to be re-pointed.
    case main
    /// A dedicated venv the bridge discovers by `envVar` (falling back to `candidateAbsolutePaths`). Mirrors
    /// the AudioGen isolated runtime so heavy, conflict-prone deps (e.g. a second torch) stay off the main env.
    /// `candidateAbsolutePaths` are venv-root paths (the python is `<root>/bin/python`); the installer builds
    /// the first whose parent is creatable, preferring the SSD assets root.
    case isolated(envVar: String, candidateAbsolutePaths: [String])
}

/// Static description of one engine: what it installs, where, what it powers, and how to detect it.
public struct GenerativeEngineSpec: Sendable, Equatable {
    public let id: GenerativeEngineID
    public let displayName: String
    public let summary: String
    /// pip requirement specifiers installed into the target venv (order preserved).
    public let pipPackages: [String]
    public let venv: EngineVenvTarget
    /// Importable top-level module used to probe "runtime present" via an on-disk site-packages check.
    public let probeModule: String
    /// Optional CLI dropped into the venv's `bin/` (mflux). If present it also satisfies the probe.
    public let probeCLI: String?
    /// Capabilities this engine powers (these gate on the engine being installed).
    public let capabilities: [CapabilityID]
    /// Approximate installed footprint of the engine's Python deps (NOT the model weights), MB.
    public let approxSizeMB: Int
    /// false → the engine (or its default model) is non-commercial (CC-BY-NC); surface a license note.
    public let commercialSafe: Bool
    public let licenseNote: String?

    public init(id: GenerativeEngineID, displayName: String, summary: String, pipPackages: [String],
                venv: EngineVenvTarget, probeModule: String, probeCLI: String? = nil,
                capabilities: [CapabilityID], approxSizeMB: Int, commercialSafe: Bool, licenseNote: String? = nil) {
        self.id = id; self.displayName = displayName; self.summary = summary
        self.pipPackages = pipPackages; self.venv = venv; self.probeModule = probeModule; self.probeCLI = probeCLI
        self.capabilities = capabilities; self.approxSizeMB = approxSizeMB
        self.commercialSafe = commercialSafe; self.licenseNote = licenseNote
    }
}

public enum GenerativeEngineCatalog {
    /// The isolated AudioGen venv path the Python bridge already discovers (`_isolated_audiogen_python()` /
    /// `DoctorService.audioRuntimeStatus`). Installing here means SFX works at execution time with no env
    /// plumbing. `~` is expanded at use.
    static let audiogenVenvHome = "~/.esh/runtime/audio/audiogen-mlx/venv"
    static let audiogenVenvSSD = "/Volumes/Sviat SSD/esh-runtime/audio/audiogen-mlx/venv"

    public static let all: [GenerativeEngineSpec] = [
        .init(id: .image, displayName: "Image engine (mflux)",
              summary: "Create images from text and edit photos (FLUX.2 Klein, Qwen edit, style adapters).",
              pipPackages: ["mflux"], venv: .main, probeModule: "mflux", probeCLI: "mflux-generate",
              capabilities: [.imageGenerate, .imageEdit], approxSizeMB: 120,
              commercialSafe: true, licenseNote: "Default backends are Apache-2.0 (commercial-safe); the FLUX kontext edit backend is non-commercial."),
        .init(id: .soundFX, displayName: "Sound FX engine (AudioGen)",
              summary: "Generate sound effects and ambiences from a description.",
              pipPackages: ["mlx-audiocraft==0.1.0"],
              venv: .isolated(envVar: "ESH_AUDIOGEN_PYTHON", candidateAbsolutePaths: [audiogenVenvSSD, audiogenVenvHome]),
              probeModule: "mlx_audiocraft",
              capabilities: [.audioGenerate], approxSizeMB: 400,
              commercialSafe: false, licenseNote: "AudioGen weights are CC-BY-NC-4.0 — non-commercial use only."),
        .init(id: .music, displayName: "Music engine (MusicGen)",
              summary: "Compose short musical loops and scores from a description.",
              pipPackages: ["torch", "transformers", "soundfile"], venv: .main, probeModule: "torch",
              capabilities: [.musicGenerate], approxSizeMB: 2600,
              commercialSafe: false, licenseNote: "MusicGen weights are CC-BY-NC-4.0 — non-commercial use only."),
        .init(id: .upscale, displayName: "Upscale engine (Real-ESRGAN)",
              summary: "Increase image resolution with Real-ESRGAN.",
              pipPackages: ["onnxruntime", "pillow"], venv: .main, probeModule: "onnxruntime",
              capabilities: [.imageUpscale], approxSizeMB: 90,
              commercialSafe: true, licenseNote: nil),
        .init(id: .removeBG, displayName: "Background removal (rembg)",
              summary: "Cut the subject out of a photo (remove the background).",
              pipPackages: ["rembg", "onnxruntime"], venv: .main, probeModule: "rembg",
              capabilities: [.imageSegment], approxSizeMB: 120,
              commercialSafe: true, licenseNote: nil),
        .init(id: .diarize, displayName: "Speaker labelling (sherpa-onnx)",
              summary: "Label who spoke when in an audio clip.",
              pipPackages: ["sherpa-onnx", "soundfile"], venv: .main, probeModule: "sherpa_onnx",
              capabilities: [.audioDiarize], approxSizeMB: 60,
              commercialSafe: true, licenseNote: nil),
    ]

    public static func spec(_ id: GenerativeEngineID) -> GenerativeEngineSpec {
        all.first { $0.id == id }!
    }

    /// The engine that powers a capability, if any (image.generate/edit → image, audio.generate → sound-fx, …).
    public static func engine(forCapability cap: CapabilityID) -> GenerativeEngineSpec? {
        all.first { $0.capabilities.contains(cap) }
    }
}
