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
        /// Local path within the repo cache the loader reads, e.g. "unet/diffusion_pytorch_model.safetensors".
        public let relativePath: String
        /// Optional lowercase hex SHA-256 for integrity verification (strongly recommended for weights).
        public let sha256: String?
        /// >1 means the file is hosted as `<relativePath>.000`, `.001`, … and concatenated on download
        /// (to stay under a host's per-file size limit, e.g. GitHub release assets' 2 GB cap).
        public let shardCount: Int
        /// Optional path to FETCH from (`baseURL + sourceRelativePath`) when it differs from the local
        /// `relativePath` — e.g. fetch a lighter `.fp16.safetensors` but store it under the preset's non-fp16
        /// name so the loader (which converts to fp16 in memory anyway) finds it. Defaults to `relativePath`.
        public let sourceRelativePath: String?
        public init(relativePath: String, sha256: String? = nil, shardCount: Int = 1,
                    sourceRelativePath: String? = nil) {
            self.relativePath = relativePath; self.sha256 = sha256; self.shardCount = max(1, shardCount)
            self.sourceRelativePath = sourceRelativePath
        }
    }

    public init(modelID: String, baseURL: URL, files: [Entry]) {
        self.modelID = modelID; self.baseURL = baseURL; self.files = files
    }

    /// Default community mirror of SD 2.1 base in diffusers layout. The original
    /// `stabilityai/stable-diffusion-2-1-base` repo was made private/deprecated by Stability AI in late
    /// 2025 (404/401 anonymously); this mirror carries the same diffusers weights and is publicly fetchable.
    public static let stableDiffusion21BaseMirror =
        URL(string: "https://huggingface.co/Manojb/stable-diffusion-2-1-base/resolve/main")!

    /// SD 2.1 base (OpenRAIL-M) served from a public mirror into the MLX StableDiffusion `.base` preset's
    /// cache layout. `modelID` MUST match the preset id so the loader finds the files locally after prefetch.
    /// The multi-GB weights are pinned to the mirror's SHA-256 (LFS oids) so a corrupted/partial download is
    /// rejected; the small JSON/tokenizer files are unpinned. Weights land on the configured storage volume.
    public static func stableDiffusion21Base(mirror: URL = stableDiffusion21BaseMirror) -> SelfHostedModel {
        SelfHostedModel(modelID: "stabilityai/stable-diffusion-2-1-base", baseURL: mirror, files: [
            Entry(relativePath: "unet/config.json"),
            Entry(relativePath: "unet/diffusion_pytorch_model.safetensors",
                  sha256: "6dfae3e5f7d459b50f4b0850ead945972c75bb0e1897628933e169eb43974214"),
            Entry(relativePath: "text_encoder/config.json"),
            Entry(relativePath: "text_encoder/model.safetensors",
                  sha256: "cce6febb0b6d876ee5eb24af35e27e764eb4f9b1d0b7c026c8c3333d4cfc916c"),
            Entry(relativePath: "vae/config.json"),
            Entry(relativePath: "vae/diffusion_pytorch_model.safetensors",
                  sha256: "a1d993488569e928462932c8c38a0760b874d166399b14414135bd9c42df5815"),
            Entry(relativePath: "scheduler/scheduler_config.json"),
            Entry(relativePath: "tokenizer/vocab.json"),
            Entry(relativePath: "tokenizer/merges.txt"),
        ])
    }

    /// Token-free source for SDXL-Turbo (`image.edit`, SDXL-Turbo img2img). `stabilityai/sdxl-turbo` errors
    /// with "Authentication required" through swift-transformers' Hub metadata path, but its `/resolve/main`
    /// LFS files are anonymously fetchable — and `SelfHostedFetcher` fetches those directly with a plain
    /// URLSession, bypassing the Hub auth entirely (same mechanism as `stableDiffusion21Base`). So the default
    /// mirror is the upstream repo's resolve endpoint; pass `mirror:` to point at an independent host if
    /// upstream ever gates `/resolve`. The four multi-GB safetensors are pinned to their git-LFS sha256 (a
    /// corrupted/partial download is rejected); the small JSON/tokenizer files are unpinned.
    public static let sdxlTurboMirror =
        URL(string: "https://huggingface.co/stabilityai/sdxl-turbo/resolve/main")!

    /// - Parameter fp16: when true (default), fetch the `.fp16.safetensors` weights (~7 GB) — lighter to
    ///   download and load; the MLX loader runs in fp16 anyway. Set false for the full fp32 weights (~13 GB).
    ///   Either way the files are stored under the preset's non-fp16 names via `Entry.sourceRelativePath`.
    public static func sdxlTurbo(mirror: URL = sdxlTurboMirror, fp16: Bool = true) -> SelfHostedModel {
        // A weight entry: fetch the fp16 variant (stored under the fp32 dest name) or the fp32 file directly.
        func weight(_ dest: String, fp16Source: String, sha16: String, sha32: String) -> Entry {
            fp16 ? Entry(relativePath: dest, sha256: sha16, sourceRelativePath: fp16Source)
                 : Entry(relativePath: dest, sha256: sha32)
        }
        return SelfHostedModel(modelID: "stabilityai/sdxl-turbo", baseURL: mirror, files: [
            Entry(relativePath: "unet/config.json"),
            weight("unet/diffusion_pytorch_model.safetensors",
                   fp16Source: "unet/diffusion_pytorch_model.fp16.safetensors",
                   sha16: "48fa46161a745f48d4054df3fe13804ee255486bca893403b60373c188fd1bdb",
                   sha32: "1968fc61aa8449ab3d3f9b9a05bce88c611760c01e0c4a7a3785911b546fe582"),
            Entry(relativePath: "text_encoder/config.json"),
            weight("text_encoder/model.safetensors",
                   fp16Source: "text_encoder/model.fp16.safetensors",
                   sha16: "660c6f5b1abae9dc498ac2d21e1347d2abdb0cf6c0c0c8576cd796491d9a6cdd",
                   sha32: "778d02eb9e707c3fbaae0b67b79ea0d1399b52e624fb634f2f19375ae7c047c3"),
            Entry(relativePath: "text_encoder_2/config.json"),
            weight("text_encoder_2/model.safetensors",
                   fp16Source: "text_encoder_2/model.fp16.safetensors",
                   sha16: "ec310df2af79c318e24d20511b601a591ca8cd4f1fce1d8dff822a356bcdb1f4",
                   sha32: "fa5b2e6f4c2efc2d82e4b8312faec1a5540eabfc6415126c9a05c8436a530ef4"),
            Entry(relativePath: "vae/config.json"),
            weight("vae/diffusion_pytorch_model.safetensors",
                   fp16Source: "vae/diffusion_pytorch_model.fp16.safetensors",
                   sha16: "02ee4bd18e5d16e7fe5fc5b85b4aefa2cba6db28897f674226c9d6ddd2f34f06",
                   sha32: "716971093e3428c9156906fcbcc5500abf005317c5f4d3a5bb3fa28c45e1e071"),
            Entry(relativePath: "scheduler/scheduler_config.json"),
            Entry(relativePath: "tokenizer/vocab.json"),
            Entry(relativePath: "tokenizer/merges.txt"),
            Entry(relativePath: "tokenizer_2/vocab.json"),
            Entry(relativePath: "tokenizer_2/merges.txt"),
        ])
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
            let source = entry.sourceRelativePath ?? entry.relativePath   // fetch path (may differ from dest)
            if entry.shardCount <= 1 {
                try await download(from: model.baseURL.appending(path: source), to: dest)
            } else {
                try await downloadShards(base: model.baseURL.appending(path: source),
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
    public static func mlxGenerate(engine: SDEngine = sharedEngine, downloadBase: URL? = nil) -> ImageGenFn {
        { prompt, params in
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        // Disable swift-transformers' async offline detection (see EshVision for the rationale).
                        // `downloadBase` routes weights to the configured storage volume (external SSD).
                        // Thread the connected HF token (nil → env fallback) so gated weights resolve.
                        let hub = HubApi(downloadBase: downloadBase, hfToken: KeychainHFCredentialStore().loadToken(), useOfflineMode: false)
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
                                 selfHosted: SelfHostedModel? = nil,
                                 downloadBase: URL? = nil) -> [any CapabilityProvider] {
        let engine = selfHosted.map { SDEngine(selfHosted: $0) } ?? sharedEngine
        let readyProbe: @Sendable () -> Bool = { false }  // conservative: requiresDownload until first load
        return [MLXImageGenerateProvider(modelID: modelID, supported: isSupportedPlatform,
                                         generate: mlxGenerate(engine: engine, downloadBase: downloadBase),
                                         readyProbe: readyProbe)]
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
            additionalProviders: EshImageGen.providers(modelID: modelID, selfHosted: selfHosted,
                                                       downloadBase: root.huggingFaceCacheURL))
    }
}
