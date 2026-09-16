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
        [
            CompatibilityEngineManifest(
                id: .music, version: "1", capabilities: [.musicGenerate],
                acceptedInputs: [.text], producedOutputs: [.audio], producedArtifactKind: .audio,
                runtimeVersion: "esh-compat-1", minimumOS: "macOS 14",
                requiredModules: [
                    .init(module: "torch", pipPackage: "torch"),
                    .init(module: "transformers", pipPackage: "transformers"),
                    .init(module: "soundfile", pipPackage: "soundfile"),
                ],
                modelAssets: [.init(id: "musicgen", displayName: "MusicGen", approxBytes: 2_400_000_000)]),

            CompatibilityEngineManifest(
                id: .soundFX, version: "1", capabilities: [.audioGenerate],
                acceptedInputs: [.text], producedOutputs: [.audio], producedArtifactKind: .audio,
                runtimeVersion: "esh-compat-1", minimumOS: "macOS 14",
                requiredModules: [
                    .init(module: "audiocraft", pipPackage: "mlx-audiocraft==0.1.0"),
                    .init(module: "soundfile", pipPackage: "soundfile"),
                ],
                modelAssets: [.init(id: "audiogen", displayName: "AudioGen", approxBytes: 1_600_000_000)]),

            CompatibilityEngineManifest(
                id: .advancedImageEdit, version: "1", capabilities: [.imageEdit],
                acceptedInputs: [.image, .text], producedOutputs: [.image], producedArtifactKind: .image,
                runtimeVersion: "esh-compat-1", minimumOS: "macOS 14",
                requiredModules: [.init(module: "mflux", pipPackage: "mflux")],
                modelAssets: [.init(id: "flux2-klein", displayName: "FLUX.2 Klein", approxBytes: 8_600_000_000)]),

            CompatibilityEngineManifest(
                id: .diarization, version: "1", capabilities: [.audioDiarize],
                acceptedInputs: [.audio], producedOutputs: [.json], producedArtifactKind: .json,
                runtimeVersion: "esh-compat-1", minimumOS: "macOS 14",
                requiredModules: [
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
