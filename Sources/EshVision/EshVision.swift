import Foundation
import EshCore
import EshRuntime
import Hub
import HuggingFace
import MLXLMCommon
import MLXVLM
import Tokenizers

// Public entry points for native image understanding (VLM) via MLX-Swift (mlx-swift-examples). A consumer
// calls `EshRuntime.makeWithVision()` (or passes `EshVision.providers()` to `makeDefault`) and uses the
// normal `execute`/`stream`/`capabilityAvailability` facade — no MLX types leak out. iOS + macOS on-device;
// no Python. The VLM weights download from Hugging Face on first use and the loaded model is cached and
// reused across requests.

/// Caches loaded MLX model containers so repeated requests reuse the same in-memory model (reuse criterion).
public actor MLXModelCache {
    private var containers: [String: ModelContainer] = [:]
    public init() {}
    func cached(_ id: String) -> ModelContainer? { containers[id] }
    func store(_ id: String, _ container: ModelContainer) { containers[id] = container }
    func isLoaded(_ id: String) -> Bool { containers[id] != nil }
}

public enum EshVision {
    /// MLX runs on Apple silicon (macOS + iOS device). Kept true so discovery reports a real state; the model
    /// downloads on first use.
    public static var isSupportedPlatform: Bool { true }

    /// Small, permissively-licensed default VLM (Apache/Tongyi). Consumers can pick another MLX VLM id.
    public static let defaultModelID = "mlx-community/Qwen2-VL-2B-Instruct-4bit"

    public static let sharedCache = MLXModelCache()

    /// The MLX-backed token stream: load (or reuse) the VLM container, then stream a response for the
    /// image + prompt. Cancelling the returned stream cancels generation. `downloadBase`, when provided,
    /// routes weight downloads to the configured storage volume (external SSD) instead of the internal
    /// default (`~/Documents/huggingface`).
    public static func mlxStream(modelID: String, cache: MLXModelCache = sharedCache,
                                 downloadBase: URL? = nil) -> VLMStreamFn {
        { imagePath, prompt in
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let container: ModelContainer
                        if let cached = await cache.cached(modelID) {
                            container = cached
                        } else {
                            // Disable swift-transformers' automatic offline detection: its NWPathMonitor
                            // delivers the first path callback asynchronously, so a fresh process would
                            // otherwise fail the very first download with a spurious "Offline mode error"
                            // before connectivity is known. Weights still download from Hugging Face, into
                            // `downloadBase` (the configured assets volume) when provided.
                            // Thread the connected HF token (nil → env fallback) so gated weights resolve.
                            // mlx-swift-lm 3.x replaced `loadContainer(hub:configuration:)` with
                            // `loadContainer(from:using:configuration:)` taking a `Downloader` + a
                            // `TokenizerLoader`. Build a HubClient pointed at `downloadBase` (the external
                            // SSD assets volume, when provided) carrying the connected HF token, and wrap it
                            // in small bridges (below) so EshVision stays swift-syntax-free — i.e. it does
                            // NOT pull mlx-swift-lm's `MLXHuggingFace` macro module into the portable graph.
                            let token = KeychainHFCredentialStore().loadToken()
                            let hubCache = downloadBase.map { HubCache(cacheDirectory: $0) } ?? .default
                            let tokenProvider: TokenProvider = token.map { .fixed(token: $0) } ?? .environment
                            let hubClient = HubClient(
                                host: HubClient.defaultHost, tokenProvider: tokenProvider, cache: hubCache)
                            container = try await VLMModelFactory.shared.loadContainer(
                                from: EshHubDownloader(hubClient),
                                using: EshTransformersTokenizerLoader(),
                                configuration: ModelConfiguration(id: modelID))
                            await cache.store(modelID, container)
                        }
                        let session = ChatSession(container)
                        let url = URL(fileURLWithPath: imagePath)
                        for try await token in session.streamResponse(to: prompt, image: .url(url)) {
                            try Task.checkCancellation()
                            continuation.yield(token)
                        }
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

    /// The `image.understand` provider(s) to register. Pass to `makeDefault(additionalProviders:)`.
    /// `downloadBase` routes VLM weight downloads to the configured storage volume (external SSD).
    public static func providers(modelID: String = defaultModelID,
                                 downloadBase: URL? = nil) -> [any CapabilityProvider] {
        let cache = sharedCache
        let readyProbe: @Sendable () -> Bool = { false }  // conservative: requiresDownload until first load
        return [MLXVisionUnderstandProvider(modelID: modelID, supported: isSupportedPlatform,
                                            stream: mlxStream(modelID: modelID, cache: cache, downloadBase: downloadBase),
                                            readyProbe: readyProbe)]
    }
}

public extension EshRuntime {
    /// A runtime with the portable native providers AND native MLX image understanding (`image.understand`).
    /// iOS + macOS; no Python. The VLM downloads on first use.
    static func makeWithVision(
        modelID: String = EshVision.defaultModelID,
        backends: [BackendKind: any InferenceBackend] = [.apple: AppleBackend()],
        root: PersistenceRoot = .default(),
        installProvider: EshInstallProviding = FileInstallProvider()
    ) async -> EshRuntime {
        await EshRuntime.makeDefault(
            backends: backends, root: root, installProvider: installProvider,
            additionalProviders: EshVision.providers(modelID: modelID, downloadBase: root.huggingFaceCacheURL))
    }
}

// MARK: - mlx-swift-lm 3.x HuggingFace bridges
//
// mlx-swift-lm 3.x loads models through a `Downloader` + `TokenizerLoader` and ships
// `MLXHuggingFace` macros (`#hubDownloader`, `#huggingFaceTokenizerLoader`,
// `#adaptHuggingFaceTokenizer`) to generate them. Those macros pull `swift-syntax` into the
// consumer's graph; EshVision is deliberately kept swift-syntax-free (it ships in the portable
// iOS/macOS package), so these types replicate the macro expansions as plain Swift. They also let
// us supply a custom `HubClient` (external-SSD download location + connected HF token), which the
// macros' default `HubClient.default` would not.

/// Bridges a swift-huggingface `HubClient` to MLXLMCommon's `Downloader`, downloading a repo
/// snapshot into the client's (possibly SSD-rooted) cache. Mirrors `#hubDownloader`.
private struct EshHubDownloader: MLXLMCommon.Downloader {
    private let upstream: HubClient
    init(_ upstream: HubClient) { self.upstream = upstream }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repoID = HuggingFace.Repo.ID(rawValue: id) else {
            throw EshVisionDownloadError.invalidRepositoryID(id)
        }
        return try await upstream.downloadSnapshot(
            of: repoID,
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: { @MainActor progress in progressHandler(progress) })
    }
}

/// Loads an HF tokenizer from a local model directory and adapts it to MLXLMCommon's `Tokenizer`.
/// Mirrors `#huggingFaceTokenizerLoader` + `#adaptHuggingFaceTokenizer`.
private struct EshTransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return EshTokenizerBridge(upstream)
    }
}

/// Adapts a swift-transformers `Tokenizers.Tokenizer` to MLXLMCommon's `Tokenizer`.
/// Mirrors the `#adaptHuggingFaceTokenizer` bridge.
private struct EshTokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer
    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    // swift-transformers uses `decode(tokens:)` rather than `decode(tokenIds:)`.
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

private enum EshVisionDownloadError: LocalizedError {
    case invalidRepositoryID(String)
    var errorDescription: String? {
        switch self {
        case .invalidRepositoryID(let id):
            return "Invalid Hugging Face repository ID: '\(id)'. Expected 'namespace/name'."
        }
    }
}
