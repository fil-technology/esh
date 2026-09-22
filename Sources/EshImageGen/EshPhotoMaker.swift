import Foundation
import EshCore
import EshRuntime
import Hub
import MLXImageEdit
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(ImageIO)
import ImageIO
#endif

// Native PhotoMaker v1 identity-preserving tier of `image.edit` (Apache-2.0 / OpenCLIP, no InsightFace, no
// Python at runtime). Wraps the standalone mlx-swift-image-edit `PhotoMakerV1Editor`. Sibling to the
// InstructPix2Pix tier (untouched). Identity = provider (PhotoMaker v1); STYLE = an optional, swappable LoRA
// preset (default: the Apache-2.0 goofyai 3D-render style) — no branded/hardcoded style in the API.

extension SelfHostedModel {
    /// SDXL base 1.0 (fp16), token-free from the upstream resolve endpoint, pinned to a revision + SHA-256.
    /// Staged into the HubApi layout the PhotoMaker pipeline reads.
    public static func sdxlBase() -> SelfHostedModel {
        let rev = "462165984030d82259a11f4367a4eed129e94a7b"
        let base = URL(string: "https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/\(rev)")!
        return SelfHostedModel(modelID: "stabilityai/stable-diffusion-xl-base-1.0", baseURL: base, files: [
            Entry(relativePath: "unet/config.json"),
            Entry(relativePath: "unet/diffusion_pytorch_model.fp16.safetensors",
                  sha256: "83e012a805b84c7ca28e5646747c90a243c65c8ba4f070e2d7ddc9d74661e139"),
            Entry(relativePath: "text_encoder/config.json"),
            Entry(relativePath: "text_encoder/model.fp16.safetensors",
                  sha256: "660c6f5b1abae9dc498ac2d21e1347d2abdb0cf6c0c0c8576cd796491d9a6cdd"),
            Entry(relativePath: "text_encoder_2/config.json"),
            Entry(relativePath: "text_encoder_2/model.fp16.safetensors",
                  sha256: "ec310df2af79c318e24d20511b601a591ca8cd4f1fce1d8dff822a356bcdb1f4"),
            Entry(relativePath: "vae/config.json"),
            Entry(relativePath: "vae/diffusion_pytorch_model.fp16.safetensors",
                  sha256: "bcb60880a46b63dea58e9bc591abe15f8350bde47b405f9c38f4be70c6161e68"),
            Entry(relativePath: "scheduler/scheduler_config.json"),
            Entry(relativePath: "tokenizer/vocab.json"),
            Entry(relativePath: "tokenizer/merges.txt"),
            Entry(relativePath: "tokenizer_2/vocab.json"),
            Entry(relativePath: "tokenizer_2/merges.txt"),
        ])
    }

    /// Converted, Swift-loadable PhotoMaker v1 assets + the default 3D-style preset, hosted as immutable
    /// release assets (no runtime Python conversion). SHA-256-pinned.
    public static func photoMakerV1() -> SelfHostedModel {
        let base = URL(string: "https://github.com/fil-technology/mlx-swift-image-edit/releases/download/pmv1-weights-v1")!
        return SelfHostedModel(modelID: "fil-technology/photomaker-v1", baseURL: base, files: [
            Entry(relativePath: "photomaker_id_encoder.safetensors",
                  sha256: "54b8d355986ec75c44076d1df8bb5ab774e65b1eec019b040f4ae8208ddaeb34"),
            Entry(relativePath: "photomaker_lora_compact.safetensors",
                  sha256: "c8feb29e6eed12c94b5049c14811d168e1d577c999fcc1eb4cf01f7c234d8a3d"),
            Entry(relativePath: "style_3d_lora_compact.safetensors",
                  sha256: "ec2363666f3332e1fc1781ccee821c22ac246493cb3400311a72456fa59db26d"),
        ])
    }
}

/// Owns the (Sendable) package PhotoMaker editor actor; stages weights once (token-free, checksummed) then
/// warm-reuses the pipeline. Only `Data` crosses the boundary.
public actor EshPhotoMakerEngine {
    private let downloadBase: URL?
    private let styleScale: Float
    /// Square denoise + output resolution (SDXL micro-conditioning matches). A SPEED/quality knob, not a
    /// memory one: a live MLX sweep showed peak ~12.4 GB at both 1024 and 768 (weights-bound; VAE decode is
    /// already tiled). 768 ≈ 2× faster first generation at slightly lower fidelity. Clamped to a multiple of 8
    /// in [512, 1024]. Default 1024 (native SDXL / max quality).
    private let editSize: Int
    private var editor: PhotoMakerV1Editor?
    private var staged = false

    public init(downloadBase: URL? = nil, styleScale: Float = 0.7, editSize: Int = EshPhotoMaker.defaultEditSize) {
        self.downloadBase = downloadBase
        self.styleScale = styleScale
        self.editSize = EshPhotoMaker.clampedEditSize(editSize)
    }

    public var isLoaded: Bool { editor != nil }

    /// Release the resident pipeline (frees the in-process weights). Staged files on disk are kept, so a
    /// later run re-loads without re-downloading.
    public func unload() { editor = nil }

    /// Stage the SDXL base + PhotoMaker v1 assets to disk (token-free, checksummed) without generating. Safe
    /// to call ahead of time so the first edit isn't blocked on a multi-GB download. Idempotent.
    public func prewarm(onProgress: @Sendable @escaping (Double) -> Void = { _ in }) async throws {
        guard !staged else { return }
        let hub = HubApi(downloadBase: downloadBase, hfToken: KeychainHFCredentialStore().loadToken(), useOfflineMode: false)
        try await SelfHostedFetcher.prefetch(.sdxlBase(), hub: hub, onProgress: onProgress)
        try await SelfHostedFetcher.prefetch(.photoMakerV1(), hub: hub, onProgress: onProgress)
        staged = true
    }

    func run(imagePath: String, prompt: String, params: EshImageEditParams,
             onProgress: @Sendable @escaping (Double) -> Void) async throws -> Data {
        // Thread the connected HF token (nil → env fallback) so gated weights resolve.
        let hub = HubApi(downloadBase: downloadBase, hfToken: KeychainHFCredentialStore().loadToken(), useOfflineMode: false)
        let assetsDir = hub.localRepoLocation(Hub.Repo(id: "fil-technology/photomaker-v1"))
        try await prewarm(onProgress: onProgress)
        let editor = self.editor ?? PhotoMakerV1Editor(
            hubDownloadBase: downloadBase,
            idEncoderPath: assetsDir.appending(path: "photomaker_id_encoder.safetensors").path,
            loraPath: assetsDir.appending(path: "photomaker_lora_compact.safetensors").path,
            styleLoraPath: assetsDir.appending(path: "style_3d_lora_compact.safetensors").path,
            styleScale: styleScale)
        self.editor = editor

        guard let cg = Self.loadCGImage(imagePath) else { throw EshImageGenError.encodeFailed }
        // esh defaults are authoritative (app sends no options): identity subject + 3D-style preset. The
        // request text (if any) refines the scene; the "3d render" trigger drives the style LoRA.
        let scene = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let stylePrompt = (scene.isEmpty ? "a 3D animated movie character" : scene)
            + ", 3d render, 3d style, soft even lighting, highly detailed"
        let request = IdentityImageEditRequest(
            referenceImage: cg, subjectWord: "person", stylePrompt: stylePrompt,
            negativePrompt: params.negativePrompt.isEmpty
                ? "photorealistic, realistic photo, photograph, dramatic lighting, blurry, deformed, low quality"
                : params.negativePrompt,
            steps: params.steps, startMergeStep: 8, guidanceScale: params.textGuidance,
            seed: params.seed ?? 0, size: editSize)
        let out = try await editor.edit(request) { p in
            onProgress(Double(p.step) / Double(max(1, p.totalSteps)))
        }
        return try SDEngine.encodePNG(out)
    }

    static func loadCGImage(_ path: String) -> CGImage? {
        #if canImport(ImageIO) && canImport(CoreGraphics)
        guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(s, 0, nil)
        #else
        return nil
        #endif
    }
}

public enum EshPhotoMaker {
    /// SDXL-based; runs on Apple silicon (macOS today). Weights download on first use.
    public static var isSupportedPlatform: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    /// Default square edit resolution (SDXL native 1024). NOTE: this is a SPEED/quality knob, NOT a memory
    /// knob — a live sweep showed the MLX peak is ~12.4 GB at BOTH 1024 and 768 (weights-dominated: ~7.85 GB
    /// resident fp16 SDXL + a ~4.5 GB fixed working set; the VAE decode is already tiled at 512 px regardless
    /// of output size). 768 does not lower peak, but it roughly halves first-generation time (~40 s vs ~83 s
    /// for the denoise) at slightly lower fidelity — a host can opt into it via
    /// `makeWithImageEditTiers(photoMakerEditSize: 768)`. Getting the peak under ~12 GB requires quantizing
    /// the fp16 weights in the pipeline, not lowering resolution.
    public static let defaultEditSize = 1024

    /// Clamp a requested edit resolution to a valid SDXL size: a multiple of 8 within [512, 1024].
    public static func clampedEditSize(_ v: Int) -> Int { min(1024, max(512, (v / 8) * 8)) }

    /// Provider id / model family the app pins via `ExecutionRequest.model` to select this identity tier.
    public static let providerID = "mlx-photomaker-v1"
    public static let modelFamily = "photomaker-v1"
    public static let defaultModelID = "fil-technology/photomaker-v1"

    /// esh-owned resource facts for resource-aware Auto routing. Identity/high-quality tier: SDXL fp16 +
    /// PhotoMaker compact LoRAs (~10 GB on disk). `estimatedPeakMemoryGB` is now the MEASURED peak (a live
    /// sweep at 1024 and 768 both peaked at 12.36–12.38 GB — weights-bound, resolution-independent) plus a
    /// small safety margin, replacing the earlier padded 14 GB so Auto routing isn't over-conservative on
    /// 16–32 GB machines. Highest quality tier; slow first generation. The system-volume headroom covers swap
    /// for the ~12.4 GB working set + macOS.
    public static let resourceProfile = CapabilityResourceProfile(
        estimatedPeakMemoryGB: 13,           // measured ~12.4 GB peak + ~0.6 GB margin (was a padded 14)
        modelDownloadBytes: 10 * 1_073_741_824,
        installedBytes: 10 * 1_073_741_824,
        temporaryInstallBytes: 2 * 1_073_741_824,
        minimumSystemVolumeHeadroomGB: 16,   // swap headroom for the ~12.4 GB working set + macOS
        minimumAssetsVolumeHeadroomGB: 3,
        qualityTier: 100,
        latencyClass: .slow)

    public static let sharedEngine = EshPhotoMakerEngine()

    public static func mlxPhotoMakerEdit(engine: EshPhotoMakerEngine) -> InstructImageEditFn {
        { imagePath, prompt, params in
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let png = try await engine.run(imagePath: imagePath, prompt: prompt, params: params) { p in
                            continuation.yield(.progress(p))
                        }
                        continuation.yield(.image(png))
                        continuation.finish()
                    } catch is CancellationError {
                        continuation.finish(throwing: CancellationError())
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    /// The PhotoMaker identity tier of `image.edit`. Native `.mlx`; selected via `request.model =
    /// "mlx-photomaker-v1"` (or "photomaker-v1"). `downloadBase` routes weights to the configured volume.
    public static func providers(styleScale: Float = 0.7, downloadBase: URL? = nil,
                                 editSize: Int = defaultEditSize) -> [any CapabilityProvider] {
        let engine = EshPhotoMakerEngine(downloadBase: downloadBase, styleScale: styleScale, editSize: editSize)
        return [MLXInstructImageEditProvider(
            modelID: defaultModelID, supported: isSupportedPlatform,
            edit: mlxPhotoMakerEdit(engine: engine), readyProbe: { false },
            providerID: providerID, modelFamily: modelFamily,
            resourceProfile: resourceProfile,
            unload: { await engine.unload() })]
    }
}

public extension EshRuntime {
    /// A runtime with BOTH native `image.edit` tiers: PhotoMaker v1 (identity/high-quality) and
    /// InstructPix2Pix (lightweight/content-preserving). Auto uses the native-first order; the app pins a tier
    /// via `ExecutionRequest.model` ("mlx-photomaker-v1" or "mlx-instruct-image-edit"). macOS; no Python.
    static func makeWithImageEditTiers(
        backends: [BackendKind: any InferenceBackend] = [.apple: AppleBackend()],
        root: PersistenceRoot = .default(),
        installProvider: EshInstallProviding = FileInstallProvider(),
        photoMakerStyleScale: Float = 0.7,
        photoMakerEditSize: Int = EshPhotoMaker.defaultEditSize
    ) async -> EshRuntime {
        let providers = EshImageEdit.providers(downloadBase: root.huggingFaceCacheURL)
            + EshPhotoMaker.providers(styleScale: photoMakerStyleScale, downloadBase: root.huggingFaceCacheURL,
                                      editSize: photoMakerEditSize)
        return await EshRuntime.makeDefault(
            backends: backends, root: root, installProvider: installProvider, additionalProviders: providers)
    }
}
