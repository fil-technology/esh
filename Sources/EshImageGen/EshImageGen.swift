import Foundation
import EshCore
import EshRuntime
import Hub
import MLX
import StableDiffusion
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

// Public entry points for native on-device image generation (`image.generate`) via MLX-Swift's
// StableDiffusion (SD 2.1 base by default; OpenRAIL-M). A consumer calls `EshRuntime.makeWithImageGen()`
// (or passes `EshImageGen.providers()` to `makeDefault`) and uses the normal execute/stream/
// capabilityAvailability facade — no MLX types leak out. macOS (Apple silicon); no Python. The weights
// download from Hugging Face on first use and the loaded generator is cached and reused across requests.

enum EshImageGenError: Error, LocalizedError {
    case generatorUnavailable
    case encodeFailed
    var errorDescription: String? {
        switch self {
        case .generatorUnavailable: return "the image-generation model could not be created"
        case .encodeFailed: return "the generated image could not be encoded"
        }
    }
}

/// Owns the (non-Sendable) MLX generator and serializes GPU access. Only `Data` crosses the actor boundary.
public actor SDEngine {
    private let preset: StableDiffusionConfiguration.Preset
    private let loadConfiguration: LoadConfiguration
    private var generator: (any TextToImageGenerator)?
    private var loaded = false

    public init(preset: StableDiffusionConfiguration.Preset = .base,
                loadConfiguration: LoadConfiguration = LoadConfiguration(float16: true, quantize: false)) {
        self.preset = preset
        self.loadConfiguration = loadConfiguration
    }

    public var isLoaded: Bool { loaded }

    private func makeGenerator(hub: HubApi) async throws -> any TextToImageGenerator {
        if let generator { return generator }
        let config = preset.configuration
        try await config.download(hub: hub)   // fetch weights on first use
        guard let g = try config.textToImageGenerator(hub: hub, configuration: loadConfiguration) else {
            throw EshImageGenError.generatorUnavailable
        }
        g.ensureLoaded()
        generator = g
        loaded = true
        return g
    }

    /// Run the diffusion loop for one image and return PNG bytes. `onProgress` is called per denoise step.
    func run(prompt: String, params: EshImageGenParams, hub: HubApi,
             onProgress: @Sendable (Double) -> Void) async throws -> Data {
        let g = try await makeGenerator(hub: hub)
        var p = preset.configuration.defaultParameters()
        p.prompt = prompt
        p.negativePrompt = params.negativePrompt
        p.steps = params.steps
        if let seed = params.seed { p.seed = seed }
        if let cfg = params.cfgWeight { p.cfgWeight = cfg }
        p.latentSize = [params.height / 8, params.width / 8]
        p.imageCount = 1
        p.decodingBatchSize = 1

        let latents = g.generateLatents(parameters: p)
        var lastXt: MLXArray? = nil
        var step = 0
        let total = max(1, p.steps)
        for xt in latents {
            try Task.checkCancellation()
            eval(xt)
            lastXt = xt
            step += 1
            onProgress(min(1.0, Double(step) / Double(total)))
        }
        guard let lastXt else { throw EshImageGenError.encodeFailed }
        let decoder = g.detachedDecoder()
        let decoded = decoder(lastXt[0 ..< 1])
        eval(decoded)
        let pixels = ((decoded * 255).asType(.uint8))[0]   // [H, W, C] uint8
        let cg = Image(pixels).asCGImage()
        return try Self.encodePNG(cg)
    }

    static func encodePNG(_ cg: CGImage) throws -> Data {
        let data = NSMutableData()
        let type: CFString
        #if canImport(UniformTypeIdentifiers)
        type = UTType.png.identifier as CFString
        #else
        type = "public.png" as CFString
        #endif
        guard let dest = CGImageDestinationCreateWithData(data, type, 1, nil) else { throw EshImageGenError.encodeFailed }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { throw EshImageGenError.encodeFailed }
        return data as Data
    }
}

public enum EshImageGen {
    /// StableDiffusion runs on Apple silicon (macOS today). Kept true so discovery reports a real state;
    /// the model downloads on first use.
    public static var isSupportedPlatform: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    /// Default model: SD 2.1 base (OpenRAIL-M). The provider is model-agnostic; other presets can be wired.
    public static let defaultModelID = "stabilityai/stable-diffusion-2-1-base"

    public static let sharedEngine = SDEngine()

    /// The MLX-backed generation stream: download (or reuse) the SD generator, run the diffusion loop, and
    /// emit per-step progress then the final PNG. Cancelling the returned stream cancels generation.
    public static func mlxGenerate(engine: SDEngine = sharedEngine) -> ImageGenFn {
        { prompt, params in
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        // Disable swift-transformers' async offline detection (see EshVision for the rationale).
                        let hub = HubApi(useOfflineMode: false)
                        let png = try await engine.run(prompt: prompt, params: params, hub: hub) { p in
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

    /// The `image.generate` provider(s) to register. Pass to `makeDefault(additionalProviders:)`.
    public static func providers(modelID: String = defaultModelID) -> [any CapabilityProvider] {
        let engine = sharedEngine
        let readyProbe: @Sendable () -> Bool = { false }  // conservative: requiresDownload until first load
        return [MLXImageGenerateProvider(modelID: modelID, supported: isSupportedPlatform,
                                         generate: mlxGenerate(engine: engine), readyProbe: readyProbe)]
    }
}

public extension EshRuntime {
    /// A runtime with the portable native providers AND native MLX image generation (`image.generate`).
    /// macOS (Apple silicon); no Python. The SD model downloads on first use.
    static func makeWithImageGen(
        modelID: String = EshImageGen.defaultModelID,
        backends: [BackendKind: any InferenceBackend] = [.apple: AppleBackend()],
        root: PersistenceRoot = .default(),
        installProvider: EshInstallProviding = FileInstallProvider()
    ) async -> EshRuntime {
        await EshRuntime.makeDefault(
            backends: backends, root: root, installProvider: installProvider,
            additionalProviders: EshImageGen.providers(modelID: modelID))
    }
}
