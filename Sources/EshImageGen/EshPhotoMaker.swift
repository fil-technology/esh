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
    private var editor: PhotoMakerV1Editor?
    private var staged = false

    public init(downloadBase: URL? = nil, styleScale: Float = 0.7) {
        self.downloadBase = downloadBase
        self.styleScale = styleScale
    }

    public var isLoaded: Bool { editor != nil }

    func run(imagePath: String, prompt: String, params: EshImageEditParams,
             onProgress: @Sendable @escaping (Double) -> Void) async throws -> Data {
        let hub = HubApi(downloadBase: downloadBase, useOfflineMode: false)
        let assetsDir = hub.localRepoLocation(Hub.Repo(id: "fil-technology/photomaker-v1"))
        if !staged {
            try await SelfHostedFetcher.prefetch(.sdxlBase(), hub: hub, onProgress: onProgress)
            try await SelfHostedFetcher.prefetch(.photoMakerV1(), hub: hub, onProgress: onProgress)
            staged = true
        }
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
            seed: params.seed ?? 0, size: 1024)
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

    /// Provider id / model family the app pins via `ExecutionRequest.model` to select this identity tier.
    public static let providerID = "mlx-photomaker-v1"
    public static let modelFamily = "photomaker-v1"
    public static let defaultModelID = "fil-technology/photomaker-v1"

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
    public static func providers(styleScale: Float = 0.7, downloadBase: URL? = nil) -> [any CapabilityProvider] {
        let engine = EshPhotoMakerEngine(downloadBase: downloadBase, styleScale: styleScale)
        return [MLXInstructImageEditProvider(
            modelID: defaultModelID, supported: isSupportedPlatform,
            edit: mlxPhotoMakerEdit(engine: engine), readyProbe: { false },
            providerID: providerID, modelFamily: modelFamily)]
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
        photoMakerStyleScale: Float = 0.7
    ) async -> EshRuntime {
        let providers = EshImageEdit.providers(downloadBase: root.huggingFaceCacheURL)
            + EshPhotoMaker.providers(styleScale: photoMakerStyleScale, downloadBase: root.huggingFaceCacheURL)
        return await EshRuntime.makeDefault(
            backends: backends, root: root, installProvider: installProvider, additionalProviders: providers)
    }
}
