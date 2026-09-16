import Foundation
import CryptoKit
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
    case checksumMismatch(String)
    case downloadFailed(String)
    var errorDescription: String? {
        switch self {
        case .generatorUnavailable: return "the image-generation model could not be created"
        case .encodeFailed: return "the generated image could not be encoded"
        case .checksumMismatch(let f): return "downloaded weight file failed checksum verification: \(f)"
        case .downloadFailed(let f): return "could not download weight file: \(f)"
        }
    }
}

/// A self-hosted (non–Hugging Face) weight source. Lets esh serve SD weights it redistributes under the
/// model's license (e.g. SD 2.1 base, OpenRAIL-M) from its own checksummed assets, so a consumer needs NO
/// Hugging Face account, token, or accepted-gate — the files are placed into the same on-disk cache layout
/// the StableDiffusion loader reads (`HubApi.localRepoLocation`), then the model loads offline.
public struct SelfHostedModel: Sendable {
    /// The repo id whose cache layout to populate (must match the preset's id so the loader finds the files).
    public let modelID: String
    /// Base URL that each file's `relativePath` is appended to (https for production, file:// for tests).
    public let baseURL: URL
    public let files: [Entry]

    public struct Entry: Sendable {
        /// Path within the repo, e.g. "unet/diffusion_pytorch_model.safetensors".
        public let relativePath: String
        /// Optional lowercase hex SHA-256 for integrity verification (strongly recommended for weights).
        public let sha256: String?
        /// >1 means the file is hosted as `<relativePath>.000`, `.001`, … and concatenated on download
        /// (to stay under a host's per-file size limit, e.g. GitHub release assets' 2 GB cap).
        public let shardCount: Int
        public init(relativePath: String, sha256: String? = nil, shardCount: Int = 1) {
            self.relativePath = relativePath; self.sha256 = sha256; self.shardCount = max(1, shardCount)
        }
    }

    public init(modelID: String, baseURL: URL, files: [Entry]) {
        self.modelID = modelID; self.baseURL = baseURL; self.files = files
    }
}

/// Places a `SelfHostedModel`'s files into the Hub cache location, verifying checksums and skipping files
/// that are already present and valid. After this, the StableDiffusion loader finds everything locally and
/// needs no network. Cooperatively cancellable.
enum SelfHostedFetcher {
    static func prefetch(_ model: SelfHostedModel, hub: HubApi,
                         onProgress: @Sendable (Double) -> Void) async throws {
        let repo = Hub.Repo(id: model.modelID)
        let dir = hub.localRepoLocation(repo)
        let fm = FileManager.default
        let total = max(1, model.files.count)
        for (i, entry) in model.files.enumerated() {
            try Task.checkCancellation()
            let dest = dir.appending(path: entry.relativePath)
            if fm.fileExists(atPath: dest.path) {
                if entry.sha256 == nil || (try? sha256Hex(ofFileAt: dest)) == entry.sha256 {
                    onProgress(Double(i + 1) / Double(total)); continue
                }
            }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if entry.shardCount <= 1 {
                try await download(from: model.baseURL.appending(path: entry.relativePath), to: dest)
            } else {
                try await downloadShards(base: model.baseURL.appending(path: entry.relativePath),
                                         count: entry.shardCount, to: dest)
            }
            if let want = entry.sha256 {
                let got = try sha256Hex(ofFileAt: dest)
                if got != want { try? fm.removeItem(at: dest); throw EshImageGenError.checksumMismatch(entry.relativePath) }
            }
            onProgress(Double(i + 1) / Double(total))
        }
    }

    private static func download(from url: URL, to dest: URL) async throws {
        let fm = FileManager.default
        if url.isFileURL {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: url, to: dest)
            return
        }
        let (tmp, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw EshImageGenError.downloadFailed("\(url.lastPathComponent) (HTTP \(http.statusCode))")
        }
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: tmp, to: dest)
    }

    private static func downloadShards(base: URL, count: Int, to dest: URL) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        fm.createFile(atPath: dest.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dest)
        defer { try? handle.close() }
        for i in 0..<count {
            try Task.checkCancellation()
            let shardURL = base.appendingPathExtension(String(format: "%03d", i))
            let tmp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try await download(from: shardURL, to: tmp)
            let data = try Data(contentsOf: tmp)
            try handle.write(contentsOf: data)
            try? fm.removeItem(at: tmp)
        }
    }

    static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 4 * 1024 * 1024)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Owns the (non-Sendable) MLX generator and serializes GPU access. Only `Data` crosses the actor boundary.
public actor SDEngine {
    private let preset: StableDiffusionConfiguration.Preset
    private let loadConfiguration: LoadConfiguration
    private let selfHosted: SelfHostedModel?
    private var generator: (any TextToImageGenerator)?
    private var loaded = false

    public init(preset: StableDiffusionConfiguration.Preset = .base,
                loadConfiguration: LoadConfiguration = LoadConfiguration(float16: true, quantize: false),
                selfHosted: SelfHostedModel? = nil) {
        self.preset = preset
        self.loadConfiguration = loadConfiguration
        self.selfHosted = selfHosted
    }

    public var isLoaded: Bool { loaded }

    private func makeGenerator(hub: HubApi, onProgress: @Sendable (Double) -> Void) async throws -> any TextToImageGenerator {
        if let generator { return generator }
        let config = preset.configuration
        if let selfHosted {
            // esh-hosted weights: place them into the Hub cache, then load offline (no HF token/gate).
            try await SelfHostedFetcher.prefetch(selfHosted, hub: hub, onProgress: onProgress)
        } else {
            try await config.download(hub: hub)   // Hugging Face (may be gated) on first use
        }
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
        let g = try await makeGenerator(hub: hub, onProgress: onProgress)
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
    /// Provide `selfHosted` to serve weights from esh's own checksummed assets (no Hugging Face token/gate);
    /// otherwise the model downloads from Hugging Face on first use (which may be gated for some repos).
    public static func providers(modelID: String = defaultModelID,
                                 selfHosted: SelfHostedModel? = nil) -> [any CapabilityProvider] {
        let engine = selfHosted.map { SDEngine(selfHosted: $0) } ?? sharedEngine
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
        selfHosted: SelfHostedModel? = nil,
        backends: [BackendKind: any InferenceBackend] = [.apple: AppleBackend()],
        root: PersistenceRoot = .default(),
        installProvider: EshInstallProviding = FileInstallProvider()
    ) async -> EshRuntime {
        await EshRuntime.makeDefault(
            backends: backends, root: root, installProvider: installProvider,
            additionalProviders: EshImageGen.providers(modelID: modelID, selfHosted: selfHosted))
    }
}
