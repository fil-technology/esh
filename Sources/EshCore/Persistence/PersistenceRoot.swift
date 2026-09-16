import Foundation

public struct PersistenceRoot: Sendable {
    /// Internal state root (config, sessions, benchmarks, runtime, metadata). Never relocated.
    public let rootURL: URL
    /// Root under which large/relocatable assets live (models, caches, audio, temp). Defaults to
    /// `rootURL`; can point at an external volume so heavy assets live off the internal disk while
    /// lightweight config/state stays internal. See docs/STORAGE.md.
    public let assetsRootURL: URL

    // State (internal)
    public let sessionsURL: URL
    public let benchmarksURL: URL

    // Assets (relocatable)
    public let cachesURL: URL
    public let modelsURL: URL
    public let audioURL: URL
    public let tempURL: URL
    /// Generated typed artifacts (image/svg/audio/document/project bundles). Relocatable like other
    /// assets; sibling of `audioURL`. Added for the Universal Capability & Modality Runtime (2.1).
    public let artifactsURL: URL

    /// Alias for `rootURL`, for call sites that want to be explicit about the internal state root.
    public var stateRootURL: URL { rootURL }

    /// Download cache for swift-transformers (MLX-Swift) model weights — native VLM (`EshVision`) and
    /// native image generation (`EshImageGen`). Lives under the relocatable assets root so heavy weights
    /// follow the configured storage volume (external SSD) instead of defaulting to the internal disk
    /// (`~/Documents/huggingface`). Distinct from the Python bridge's Hugging Face caches, which use the
    /// `huggingface_hub` on-disk layout under `caches/audio-models` and `caches/image-models`.
    public var huggingFaceCacheURL: URL { cachesURL.appendingPathComponent("hf-swift", isDirectory: true) }

    /// The Python bridge's Hugging Face cache for a given asset family (audio: MusicGen/AudioGen; image:
    /// FLUX/mflux edit). Matches the existing on-disk `caches/<family>-models` layout so previously
    /// downloaded assets on the configured volume are reused rather than re-fetched.
    public func pythonHFCacheURL(family: String) -> URL {
        cachesURL.appendingPathComponent("\(family)-models", isDirectory: true)
    }

    /// Directory holding the diarization ONNX models (sherpa-onnx segmentation + embedding), under the
    /// relocatable audio assets so they live on the configured storage volume.
    public var diarizationModelsURL: URL { audioURL.appendingPathComponent("diarization-models", isDirectory: true) }

    /// True when assets are configured to live somewhere other than the internal state root.
    public var usesExternalAssets: Bool {
        rootURL.standardizedFileURL != assetsRootURL.standardizedFileURL
    }

    public init(rootURL: URL) {
        self.init(stateRootURL: rootURL, assetsRootURL: rootURL)
    }

    public init(stateRootURL: URL, assetsRootURL: URL) {
        self.rootURL = stateRootURL
        self.assetsRootURL = assetsRootURL
        self.sessionsURL = stateRootURL.appendingPathComponent("sessions", isDirectory: true)
        self.benchmarksURL = stateRootURL.appendingPathComponent("benchmarks", isDirectory: true)
        self.cachesURL = assetsRootURL.appendingPathComponent("caches", isDirectory: true)
        self.modelsURL = assetsRootURL.appendingPathComponent("models", isDirectory: true)
        self.audioURL = assetsRootURL.appendingPathComponent("audio", isDirectory: true)
        self.tempURL = assetsRootURL.appendingPathComponent("tmp", isDirectory: true)
        self.artifactsURL = assetsRootURL.appendingPathComponent("artifacts", isDirectory: true)
    }

    public static func `default`() -> PersistenceRoot {
        let stateRoot = resolveStateRoot()
        let assetsRoot = resolveAssetsRoot(stateRoot: stateRoot)
        return PersistenceRoot(stateRootURL: stateRoot, assetsRootURL: assetsRoot)
    }

    /// Resolve the internal state root, applying the `ESH_HOME`/`LLMCACHE_HOME` overrides and the
    /// one-time `~/.llmcache` → `~/.esh` migration.
    public static func resolveStateRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["ESH_HOME"] ?? ProcessInfo.processInfo.environment["LLMCACHE_HOME"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        let fileManager = FileManager.default

        #if os(macOS)
        // macOS: state lives at ~/.esh, with a one-time ~/.llmcache → ~/.esh migration.
        let home = fileManager.homeDirectoryForCurrentUser
        let eshRoot = home.appendingPathComponent(".esh", isDirectory: true)
        let legacyRoot = home.appendingPathComponent(".llmcache", isDirectory: true)

        migrateLegacyRootIfNeeded(
            fileManager: fileManager,
            legacyRoot: legacyRoot,
            eshRoot: eshRoot
        )

        return eshRoot
        #else
        // esh iOS M1: sandboxed platforms have no user home directory. State lives in the app's
        // Application Support container ("<AppSupport>/esh"); there is no legacy root to migrate. The
        // ESH_HOME override above still applies first. Heavy assets default here too unless relocated
        // (external-volume relocation is a macOS-only concept — see docs/IOS_RUNTIME_SPEC.md §16).
        let base = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("esh", isDirectory: true)
        #endif
    }

    /// Resolve the assets root from (1) `ESH_ASSETS_HOME` env, (2) persisted `storage.json`,
    /// otherwise the internal state root (zero-configuration default). Note: this returns the
    /// *configured* path even if an external volume is currently disconnected — callers that are
    /// about to write large assets must gate on `StorageService.availability(...)` first so a
    /// missing volume produces a clear error instead of a silent internal fallback.
    public static func resolveAssetsRoot(stateRoot: URL) -> URL {
        if let override = ProcessInfo.processInfo.environment["ESH_ASSETS_HOME"], !override.isEmpty {
            return PathResolving.directoryURL(from: override)
        }
        let config = StorageConfigStore(stateRootURL: stateRoot).load()
        if let assetsRoot = config.assetsRoot, !assetsRoot.trimmingCharacters(in: .whitespaces).isEmpty {
            return PathResolving.directoryURL(from: assetsRoot)
        }
        return stateRoot
    }

    static func migrateLegacyRootIfNeeded(
        fileManager: FileManager,
        legacyRoot: URL,
        eshRoot: URL
    ) {
        guard fileManager.fileExists(atPath: legacyRoot.path) else { return }

        if !fileManager.fileExists(atPath: eshRoot.path) {
            try? fileManager.createDirectory(at: eshRoot, withIntermediateDirectories: true)
        }

        for child in ["models", "sessions", "caches", "benchmarks"] {
            let legacyChild = legacyRoot.appendingPathComponent(child, isDirectory: true)
            let eshChild = eshRoot.appendingPathComponent(child, isDirectory: true)

            guard fileManager.fileExists(atPath: legacyChild.path) else {
                continue
            }

            if !fileManager.fileExists(atPath: eshChild.path) {
                do {
                    try fileManager.moveItem(at: legacyChild, to: eshChild)
                    continue
                } catch {
                    do {
                        try fileManager.copyItem(at: legacyChild, to: eshChild)
                        continue
                    } catch {
                        continue
                    }
                }
            }

            mergeDirectoryContents(
                fileManager: fileManager,
                sourceDirectory: legacyChild,
                destinationDirectory: eshChild
            )
        }
    }

    private static func mergeDirectoryContents(
        fileManager: FileManager,
        sourceDirectory: URL,
        destinationDirectory: URL
    ) {
        guard let items = try? fileManager.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil) else {
            return
        }

        for item in items {
            let destination = destinationDirectory.appendingPathComponent(item.lastPathComponent, isDirectory: true)
            guard !fileManager.fileExists(atPath: destination.path) else {
                if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    mergeDirectoryContents(
                        fileManager: fileManager,
                        sourceDirectory: item,
                        destinationDirectory: destination
                    )
                }
                continue
            }

            do {
                try fileManager.moveItem(at: item, to: destination)
            } catch {
                do {
                    try fileManager.copyItem(at: item, to: destination)
                } catch {
                    continue
                }
            }
        }
    }
}
