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

// Native, on-device, content-preserving INSTRUCT image editing (`image.edit`) via the standalone
// mlx-swift-image-edit package (InstructPix2Pix / SD1.5 on MLX). No Python — runs under the macOS App
// Sandbox, weights downloaded as data. A consumer registers `EshImageEdit.providers()` (or uses
// `EshRuntime.makeWithImageEdit()`) and uses the normal execute/stream/capabilityAvailability facade — no
// MLX types leak out. The editor (and its validated default 2 GB MLX cache cap) lives in the package; esh
// only stages the token-free, checksummed weights and adapts progress/cancellation/artifacts.

extension SelfHostedModel {
    /// Token-free source for InstructPix2Pix (`image.edit`). Like `sdxlTurbo`, the repo's `/resolve/main`
    /// LFS files are anonymously fetchable and `SelfHostedFetcher` downloads them directly (no Hub auth). The
    /// fp16 safetensors (~2 GB total) are staged under their upstream `.fp16` names — exactly what the package
    /// loader reads — and pinned to the on-device-validated SHA-256 (a corrupted/partial download is rejected);
    /// the small JSON/tokenizer files are unpinned. CreativeML OpenRAIL-M (commercial-OK with use restrictions).
    public static let instructPix2PixMirror =
        URL(string: "https://huggingface.co/timbrooks/instruct-pix2pix/resolve/main")!

    public static func instructPix2Pix(mirror: URL = instructPix2PixMirror) -> SelfHostedModel {
        SelfHostedModel(modelID: "timbrooks/instruct-pix2pix", baseURL: mirror, files: [
            Entry(relativePath: "unet/config.json"),
            Entry(relativePath: "unet/diffusion_pytorch_model.fp16.safetensors",
                  sha256: "0d6bbc0a95dd125196d327a660b43d24c56f433eb30d2776f1327fb86bd38f78"),
            Entry(relativePath: "text_encoder/config.json"),
            Entry(relativePath: "text_encoder/model.fp16.safetensors",
                  sha256: "77795e2023adcf39bc29a884661950380bd093cf0750a966d473d1718dc9ef4e"),
            Entry(relativePath: "vae/config.json"),
            Entry(relativePath: "vae/diffusion_pytorch_model.fp16.safetensors",
                  sha256: "4fbcf0ebe55a0984f5a5e00d8c4521d52359af7229bb4d81890039d2aa16dd7c"),
            Entry(relativePath: "scheduler/scheduler_config.json"),
            Entry(relativePath: "tokenizer/vocab.json"),
            Entry(relativePath: "tokenizer/merges.txt"),
        ])
    }
}

/// Owns the (Sendable) package editor actor and serializes staging. Weights are prefetched once (token-free,
/// checksummed) into the Hub cache the editor reads; the editor is then reused across requests (warm).
public actor InstructImageEditEngine {
    private let selfHosted: SelfHostedModel?
    private let downloadBase: URL?
    private var editor: InstructPix2PixEditor?
    private var prefetched = false

    public init(selfHosted: SelfHostedModel? = nil, downloadBase: URL? = nil) {
        self.selfHosted = selfHosted
        self.downloadBase = downloadBase
    }

    public var isLoaded: Bool { editor != nil }

    /// Release the resident pipeline (frees in-process weights); staged files on disk are kept.
    public func unload() { editor = nil }

    /// Stage weights (once), run the instruct edit for one image, and return PNG bytes. `onProgress` is
    /// called during download (0…1) and then per denoise step (0…1).
    func run(imagePath: String, prompt: String, params: EshImageEditParams,
             onProgress: @Sendable @escaping (Double) -> Void) async throws -> Data {
        if let selfHosted, !prefetched {
            // Thread the connected HF token (nil → swift-transformers' env fallback) so gated weights resolve.
            let hub = HubApi(downloadBase: downloadBase, hfToken: KeychainHFCredentialStore().loadToken(), useOfflineMode: false)
            try await SelfHostedFetcher.prefetch(selfHosted, hub: hub, onProgress: onProgress)
            prefetched = true
        }
        let editor = self.editor ?? InstructPix2PixEditor(hubDownloadBase: downloadBase)
        self.editor = editor

        guard let cg = Self.loadSourceCGImage(path: imagePath, maxEdge: params.maximumEdge) else {
            throw EshImageGenError.encodeFailed
        }
        let request = InstructImageEditRequest(
            prompt: prompt, image: cg, negativePrompt: params.negativePrompt,
            steps: params.steps, guidanceScale: params.textGuidance,
            imageGuidanceScale: params.imageGuidance, seed: params.seed ?? 0)
        let out = try await editor.edit(request) { p in
            onProgress(Double(p.step) / Double(max(1, p.totalSteps)))
        }
        return try SDEngine.encodePNG(out)
    }

    /// Load a source image and downscale so its longest edge ≤ `maxEdge`, with both dimensions rounded down
    /// to a multiple of 8 (the VAE stride InstructPix2Pix requires), in device RGB.
    static func loadSourceCGImage(path: String, maxEdge: Int) -> CGImage? {
        #if canImport(ImageIO) && canImport(CoreGraphics)
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let full = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = full.width, h = full.height
        guard w > 0, h > 0 else { return nil }
        let scale = min(1.0, Double(maxEdge) / Double(max(w, h)))
        func mult8(_ v: Double) -> Int { max(8, (Int(v) / 8) * 8) }
        let tw = mult8(Double(w) * scale), th = mult8(Double(h) * scale)
        guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(full, in: CGRect(x: 0, y: 0, width: tw, height: th))
        return ctx.makeImage()
        #else
        return nil
        #endif
    }
}

public enum EshImageEdit {
    /// InstructPix2Pix runs on Apple silicon (macOS today). The model downloads on first use.
    public static var isSupportedPlatform: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    /// Default model: InstructPix2Pix (SD1.5, CreativeML OpenRAIL-M).
    public static let defaultModelID = "timbrooks/instruct-pix2pix"

    /// Provider id the app pins via `ExecutionRequest.model` to select this lightweight tier.
    public static let defaultTierProviderID = "mlx-instruct-image-edit"

    /// esh-owned resource facts for resource-aware Auto routing. Lightweight content-preserving tier:
    /// fp16 ~2 GB weights, measured peak RSS ~7 GB. Quality tier below the PhotoMaker identity tier.
    public static let resourceProfile = CapabilityResourceProfile(
        estimatedPeakMemoryGB: 8,
        modelDownloadBytes: 2 * 1_073_741_824,
        installedBytes: 2 * 1_073_741_824,
        temporaryInstallBytes: 1 * 1_073_741_824,
        minimumSystemVolumeHeadroomGB: 12,   // swap headroom for the working set
        minimumAssetsVolumeHeadroomGB: 2,
        qualityTier: 50,
        latencyClass: .moderate)

    public static let sharedEngine = InstructImageEditEngine(selfHosted: SelfHostedModel.instructPix2Pix())

    /// The MLX-backed instruct-edit stream: stage (or reuse) the model, run the edit, emit per-step progress
    /// then the final PNG. Cancelling the returned stream cancels editing.
    public static func mlxInstructEdit(engine: InstructImageEditEngine = sharedEngine) -> InstructImageEditFn {
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

    /// The `image.edit` provider(s) to register. Pass to `makeDefault(additionalProviders:)`. `selfHosted`
    /// serves the token-free, checksummed weights (default); `downloadBase` routes them to the configured
    /// storage volume (external SSD). Native `.mlx` wins over the Python compat `image.edit` provider.
    public static func providers(modelID: String = defaultModelID,
                                 selfHosted: SelfHostedModel? = nil,
                                 downloadBase: URL? = nil) -> [any CapabilityProvider] {
        let engine = InstructImageEditEngine(selfHosted: selfHosted ?? SelfHostedModel.instructPix2Pix(),
                                             downloadBase: downloadBase)
        let readyProbe: @Sendable () -> Bool = { false }  // conservative: requiresDownload until first load
        return [MLXInstructImageEditProvider(modelID: modelID, supported: isSupportedPlatform,
                                             edit: mlxInstructEdit(engine: engine),
                                             readyProbe: readyProbe,
                                             resourceProfile: resourceProfile,
                                             unload: { await engine.unload() })]
    }
}

public extension EshRuntime {
    /// A runtime with the portable native providers AND native MLX INSTRUCT image editing (`image.edit`,
    /// InstructPix2Pix). macOS (Apple silicon); no Python. The model downloads on first use. Distinct from
    /// `makeWithImageRestyle` (SDXL-Turbo `image.restyle`).
    static func makeWithImageEdit(
        modelID: String = EshImageEdit.defaultModelID,
        selfHosted: SelfHostedModel? = nil,
        backends: [BackendKind: any InferenceBackend] = [.apple: AppleBackend()],
        root: PersistenceRoot = .default(),
        installProvider: EshInstallProviding = FileInstallProvider()
    ) async -> EshRuntime {
        await EshRuntime.makeDefault(
            backends: backends, root: root, installProvider: installProvider,
            additionalProviders: EshImageEdit.providers(modelID: modelID, selfHosted: selfHosted,
                                                        downloadBase: root.huggingFaceCacheURL))
    }
}
