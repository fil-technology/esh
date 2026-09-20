import Foundation
import EshCore
import EshRuntime
import Hub
import MLX
import StableDiffusion

// Native on-device image editing (`image.edit`) via MLX-Swift's StableDiffusion img2img (SDXL-Turbo by
// default). No Python — runs under the macOS App Sandbox, weights downloaded as data. A consumer registers
// `EshImageRestyle.providers()` (or uses `EshRuntime.makeWithImageRestyle()`) and uses the normal execute/stream/
// capabilityAvailability facade. The generator is cached and reused across requests. Reuses this module's
// SelfHostedFetcher, EshImageGenError, and SDEngine.encodePNG.

/// Owns the (non-Sendable) MLX img2img generator and serializes GPU access. Only `Data` crosses the boundary.
public actor SDImageRestyleEngine {
    private let preset: StableDiffusionConfiguration.Preset
    private let loadConfiguration: LoadConfiguration
    private let selfHosted: SelfHostedModel?
    private var generator: (any ImageToImageGenerator)?
    private var loaded = false

    public init(preset: StableDiffusionConfiguration.Preset = .sdxlTurbo,
                loadConfiguration: LoadConfiguration = LoadConfiguration(float16: true, quantize: false),
                selfHosted: SelfHostedModel? = nil) {
        self.preset = preset
        self.loadConfiguration = loadConfiguration
        self.selfHosted = selfHosted
    }

    public var isLoaded: Bool { loaded }

    private func makeGenerator(hub: HubApi, onProgress: @Sendable (Double) -> Void) async throws -> any ImageToImageGenerator {
        if let generator { return generator }
        let config = preset.configuration
        if let selfHosted {
            try await SelfHostedFetcher.prefetch(selfHosted, hub: hub, onProgress: onProgress)
        } else {
            try await config.download(hub: hub)   // Hugging Face on first use
        }
        guard let g = try config.imageToImageGenerator(hub: hub, configuration: loadConfiguration) else {
            throw EshImageGenError.generatorUnavailable
        }
        g.ensureLoaded()
        generator = g
        loaded = true
        return g
    }

    /// Run the img2img loop for one image and return PNG bytes. `onProgress` is called per denoise step.
    func run(imagePath: String, prompt: String, params: EshImageRestyleParams, hub: HubApi,
             onProgress: @Sendable (Double) -> Void) async throws -> Data {
        let g = try await makeGenerator(hub: hub, onProgress: onProgress)
        // Load the source image and normalize to [-1, 1] (the autoencoder's expected input range).
        let src = try Image(url: URL(fileURLWithPath: imagePath), maximumEdge: params.maximumEdge)
        let input = (src.data.asType(.float32) / 255) * 2 - 1

        var p = preset.configuration.defaultParameters()
        p.prompt = prompt
        p.negativePrompt = params.negativePrompt
        p.steps = params.steps
        if let seed = params.seed { p.seed = seed }
        if let cfg = params.cfgWeight { p.cfgWeight = cfg }
        p.imageCount = 1
        p.decodingBatchSize = 1
        // img2img runs only `steps * strength` denoise steps; ensure at least one.
        if Int(Float(p.steps) * params.strength) < 1 { p.steps = Int(ceil(1 / params.strength)) }
        let effectiveSteps = max(1, Int(Float(p.steps) * params.strength))

        let latents = g.generateLatents(image: input, parameters: p, strength: params.strength)
        var lastXt: MLXArray? = nil
        var step = 0
        for xt in latents {
            try Task.checkCancellation()
            eval(xt)
            lastXt = xt
            step += 1
            onProgress(min(1.0, Double(step) / Double(effectiveSteps)))
        }
        guard let lastXt else { throw EshImageGenError.encodeFailed }
        let decoder = g.detachedDecoder()
        let decoded = decoder(lastXt[0 ..< 1])
        eval(decoded)
        let pixels = ((decoded * 255).asType(.uint8))[0]   // [H, W, C] uint8
        let cg = Image(pixels).asCGImage()
        return try SDEngine.encodePNG(cg)
    }
}

public enum EshImageRestyle {
    /// SDXL-Turbo img2img runs on Apple silicon (macOS today). The model downloads on first use.
    public static var isSupportedPlatform: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    /// Default model: SDXL-Turbo (img2img). The provider is model-agnostic; other presets can be wired.
    public static let defaultModelID = "stabilityai/sdxl-turbo"

    public static let sharedEngine = SDImageRestyleEngine()

    /// The MLX-backed edit stream: load (or reuse) the img2img generator, run the loop, emit per-step
    /// progress then the final PNG. Cancelling the returned stream cancels editing.
    public static func mlxRestyle(engine: SDImageRestyleEngine = sharedEngine, downloadBase: URL? = nil) -> ImageRestyleFn {
        { imagePath, prompt, params in
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        // Disable swift-transformers' async offline detection (see EshVision); route weights
                        // to the configured storage volume (external SSD) via `downloadBase`.
                        // Thread the connected HF token (nil → env fallback) so gated weights resolve.
                        let hub = HubApi(downloadBase: downloadBase, hfToken: KeychainHFCredentialStore().loadToken(), useOfflineMode: false)
                        let png = try await engine.run(imagePath: imagePath, prompt: prompt, params: params, hub: hub) { p in
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

    /// The `image.edit` provider(s) to register. Pass to `makeDefault(additionalProviders:)`. Provide
    /// `selfHosted` to serve weights from esh's own checksummed assets (no Hugging Face token/gate);
    /// otherwise the model downloads from Hugging Face on first use.
    public static func providers(modelID: String = defaultModelID,
                                 selfHosted: SelfHostedModel? = nil,
                                 downloadBase: URL? = nil) -> [any CapabilityProvider] {
        let engine = selfHosted.map { SDImageRestyleEngine(selfHosted: $0) } ?? sharedEngine
        let readyProbe: @Sendable () -> Bool = { false }  // conservative: requiresDownload until first load
        return [MLXImageRestyleProvider(modelID: modelID, supported: isSupportedPlatform,
                                     edit: mlxRestyle(engine: engine, downloadBase: downloadBase),
                                     readyProbe: readyProbe)]
    }
}

public extension EshRuntime {
    /// A runtime with the portable native providers AND native MLX image editing (`image.edit`, SDXL-Turbo
    /// img2img). macOS (Apple silicon); no Python. The model downloads on first use.
    static func makeWithImageRestyle(
        modelID: String = EshImageRestyle.defaultModelID,
        selfHosted: SelfHostedModel? = nil,
        backends: [BackendKind: any InferenceBackend] = [.apple: AppleBackend()],
        root: PersistenceRoot = .default(),
        installProvider: EshInstallProviding = FileInstallProvider()
    ) async -> EshRuntime {
        await EshRuntime.makeDefault(
            backends: backends, root: root, installProvider: installProvider,
            additionalProviders: EshImageRestyle.providers(modelID: modelID, selfHosted: selfHosted,
                                                        downloadBase: root.huggingFaceCacheURL))
    }
}
