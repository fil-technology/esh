import Foundation
import EshCore
import EshRuntime

// Public entry points for the esh-owned macOS compatibility runtime. A consumer never builds a host,
// manifest, or provider — it calls `EshRuntime.makeWithMacCapabilities()` (or passes the providers to
// `makeDefault`) and then uses the normal `execute`/`stream`/`capabilityAvailability` facade. On non-macOS
// platforms the engines register but report `.unsupportedOnPlatform`.

public enum MacCapabilities {
    /// Whether the compatibility engines can run on the current platform (macOS only).
    public static var isSupportedPlatform: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    /// The declared manifests for every compatibility engine. One coherent place owns each engine's
    /// dependencies + model assets (§4). NOTE: `soundfile` is a REQUIRED module of the music/SFX/diarization
    /// engines here — the regression that produced `ModuleNotFoundError: No module named 'soundfile'` is now
    /// caught by preflight as `.repairRequired`, not a raw traceback (§3/§6).
    public static func manifests() -> [CompatibilityEngineManifest] {
        // Every engine runs through the shared bridge (mlx_vlm_bridge.py), which imports these at load time —
        // so they're required for ANY engine and preflight must catch them (validated: a fresh venv missing
        // mlx_lm reported repairRequired before this was declared).
        let base: [CompatibilityModule] = [
            .init(module: "numpy", pipPackage: "numpy"),
            .init(module: "mlx", pipPackage: "mlx"),
            .init(module: "mlx_lm", pipPackage: "mlx-lm"),
        ]
        return [
            CompatibilityEngineManifest(
                id: .music, version: "1", capabilities: [.musicGenerate],
                acceptedInputs: [.text], producedOutputs: [.audio], producedArtifactKind: .audio,
                runtimeVersion: "esh-compat-1", minimumOS: "macOS 14",
                requiredModules: base + [
                    .init(module: "torch", pipPackage: "torch"),
                    .init(module: "transformers", pipPackage: "transformers"),
                    .init(module: "soundfile", pipPackage: "soundfile"),
                ],
                modelAssets: [.init(id: "musicgen", displayName: "MusicGen", approxBytes: 2_400_000_000)]),

            // Environmental SFX via AudioGen (mlx-audiocraft) in an ISOLATED venv — its audiocraft/
            // multiprocessing stack is kept out of the shared MLX runtime. The shared bridge (main venv) only
            // launches the isolated worker, so its own required modules are just the `base` bridge deps; the
            // AudioGen deps are probed/installed against the isolated venv the host points the bridge at via
            // `ESH_AUDIOGEN_PYTHON`. (Before rc.30 these were declared as top-level `requiredModules` and so
            // were falsely probed against the main venv → a spurious "missing module 'mlx_audiocraft'".)
            CompatibilityEngineManifest(
                id: .soundFX, version: "1", capabilities: [.audioGenerate],
                acceptedInputs: [.text], producedOutputs: [.audio], producedArtifactKind: .audio,
                runtimeVersion: "esh-compat-1", minimumOS: "macOS 14",
                requiredModules: base,
                modelAssets: [.init(id: "audiogen", displayName: "AudioGen", approxBytes: 1_600_000_000)],
                isolatedRuntime: .init(dirName: "audiogen-venv", envVar: "ESH_AUDIOGEN_PYTHON", modules: [
                    // The isolated AudioGen runtime imports `mlx_audiocraft` (underscore); the pip package is
                    // `mlx-audiocraft`. Declaring the correct import name so preflight probes it accurately.
                    .init(module: "numpy", pipPackage: "numpy"),
                    .init(module: "soundfile", pipPackage: "soundfile"),
                    .init(module: "mlx_audiocraft", pipPackage: "mlx-audiocraft==0.1.0"),
                ])),

            // macOS text->image generation via mflux's Z-Image-Turbo (Apache-2.0, ~8 steps). The 4-bit
            // model is already present on the configured assets volume; no gated repo, no token. The native
            // MLX-Swift SD path (EshImageGen) is the separate iOS-native workstream.
            CompatibilityEngineManifest(
                id: .imageGeneration, version: "1", capabilities: [.imageGenerate],
                acceptedInputs: [.text], producedOutputs: [.image], producedArtifactKind: .image,
                runtimeVersion: "esh-compat-1", minimumOS: "macOS 14",
                requiredModules: base + [.init(module: "mflux", pipPackage: "mflux")],
                modelAssets: [.init(id: "z-image-turbo", displayName: "Z-Image Turbo (mflux 4-bit)", approxBytes: 6_500_000_000)]),

            CompatibilityEngineManifest(
                id: .advancedImageEdit, version: "1", capabilities: [.imageEdit],
                acceptedInputs: [.image, .text], producedOutputs: [.image], producedArtifactKind: .image,
                runtimeVersion: "esh-compat-1", minimumOS: "macOS 14",
                requiredModules: base + [.init(module: "mflux", pipPackage: "mflux")],
                modelAssets: [.init(id: "flux2-klein", displayName: "FLUX.2 Klein", approxBytes: 8_600_000_000)]),

            // Zero-shot voice cloning via Coqui XTTS-v2 (coqui-tts `TTS`). License: Coqui Public Model License
            // (CPML) — NON-COMMERCIAL, so dogfood-only, exactly like MusicGen/AudioGen. Clones the voice from a
            // short reference-audio sample and speaks the supplied text.
            //
            // Dependency pins below were VALIDATED by a live end-to-end clone (real 24 kHz WAV from XTTS-v2):
            //   • `torchaudio` is REQUIRED by XTTS (not optional).
            //   • `torch`/`torchaudio` pinned < 2.9 — 2.9+ requires `torchcodec` (+ system FFmpeg) for audio IO.
            //   • `transformers` pinned >=4.57,<5 — coqui-tts 0.27.x needs >=4.57, and 5.x drops
            //     `isin_mps_friendly` which XTTS imports.
            // Because `transformers<5` clashes with the main runtime's newer transformers, this engine runs in
            // its OWN isolated venv (rc.30), exactly like AudioGen — the shared bridge (main venv) only launches
            // the isolated `esh_voiceclone.py` worker, located via `ESH_VOICECLONE_PYTHON`. The pinned deps
            // below are probed/installed against that isolated venv, never the shared one. exFAT venvs also need
            // AppleDouble (`._*`) stripping, which the host + worker already perform.
            CompatibilityEngineManifest(
                id: .voiceClone, version: "1", capabilities: [.audioCloneVoice],
                acceptedInputs: [.audio, .text], producedOutputs: [.audio], producedArtifactKind: .audio,
                runtimeVersion: "esh-compat-1", minimumOS: "macOS 14",
                requiredModules: base,
                modelAssets: [.init(id: "xtts-v2", displayName: "XTTS-v2 (voice clone)", approxBytes: 1_870_000_000)],
                isolatedRuntime: .init(dirName: "voiceclone-venv", envVar: "ESH_VOICECLONE_PYTHON", modules: [
                    .init(module: "numpy", pipPackage: "numpy"),
                    .init(module: "torch", pipPackage: "torch<2.9"),
                    .init(module: "torchaudio", pipPackage: "torchaudio<2.9"),
                    .init(module: "transformers", pipPackage: "transformers>=4.57,<5"),
                    .init(module: "TTS", pipPackage: "coqui-tts"),
                    .init(module: "soundfile", pipPackage: "soundfile"),
                ])),

            CompatibilityEngineManifest(
                id: .diarization, version: "1", capabilities: [.audioDiarize],
                acceptedInputs: [.audio], producedOutputs: [.json], producedArtifactKind: .json,
                runtimeVersion: "esh-compat-1", minimumOS: "macOS 14",
                requiredModules: base + [
                    .init(module: "sherpa_onnx", pipPackage: "sherpa-onnx"),
                    .init(module: "soundfile", pipPackage: "soundfile"),
                ],
                modelAssets: [.init(id: "diarization", displayName: "Speaker diarization", approxBytes: 200_000_000)]),
        ]
    }

    /// Build the compatibility capability providers for a host. Pass to `makeDefault(additionalProviders:)`.
    public static func providers(host: CompatibilityEngineHost) -> [any CapabilityProvider] {
        manifests().map { CompatibilityCapabilityProvider(manifest: $0, host: host, supported: isSupportedPlatform) }
    }
}

public extension EshRuntime {
    /// A runtime with the portable native providers AND the macOS compatibility engines (music, SFX,
    /// advanced image edit, diarization) wired behind the same facade. `host` owns the runtime detail; the
    /// default concrete host (`EshManagedPythonHost`) is esh-managed and requires no consumer Python/CLI/
    /// Homebrew. On non-macOS the compatibility engines report `.unsupportedOnPlatform`.
    static func makeWithMacCapabilities(
        host: CompatibilityEngineHost,
        backends: [BackendKind: any InferenceBackend] = [.apple: AppleBackend()],
        root: PersistenceRoot = .default(),
        installProvider: EshInstallProviding = FileInstallProvider()
    ) async -> EshRuntime {
        await EshRuntime.makeDefault(
            backends: backends, root: root, installProvider: installProvider,
            additionalProviders: MacCapabilities.providers(host: host))
    }
}
