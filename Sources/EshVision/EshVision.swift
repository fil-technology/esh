import Foundation
import EshCore
import EshRuntime
import Hub
import MLXLMCommon
import MLXVLM

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
                            let hub = HubApi(downloadBase: downloadBase, useOfflineMode: false)
                            container = try await VLMModelFactory.shared.loadContainer(
                                hub: hub, configuration: ModelConfiguration(id: modelID))
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
