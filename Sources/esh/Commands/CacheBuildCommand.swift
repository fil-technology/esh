import Foundation
import EshCore

enum CacheBuildCommand {
    static func run(arguments: [String]) async throws {
        let sessionIdentifier = try CommandSupport.requiredValue(flag: "--session", in: arguments)
        let modeValue = CommandSupport.optionalValue(flag: "--mode", in: arguments) ?? "auto"
        let intentValue = CommandSupport.optionalValue(flag: "--intent", in: arguments) ?? SessionIntent.chat.rawValue
        let modelID = CommandSupport.optionalValue(flag: "--model", in: arguments)

        guard let mode = CacheMode(rawValue: modeValue.lowercased()) else {
            throw StoreError.invalidManifest("Invalid cache mode: \(modeValue)")
        }
        guard let intent = SessionIntent(rawValue: intentValue.lowercased()) else {
            throw StoreError.invalidManifest("Invalid session intent: \(intentValue)")
        }

        let root = PersistenceRoot.default()
        let sessionStore = FileSessionStore(root: root)
        let modelStore = FileModelStore(root: root)
        let cacheStore = FileCacheStore(root: root)
        var session = try CommandSupport.resolveSession(identifier: sessionIdentifier, sessionStore: sessionStore)
        let install = try CommandSupport.resolveInstall(
            identifier: modelID,
            modelStore: modelStore,
            preferredModelID: session.modelID
        )
        guard install.spec.backend == .mlx else {
            throw StoreError.invalidManifest("Cache build currently supports MLX models only.")
        }
        let backend = MLXBackend()
        let runtime = try await backend.loadRuntime(for: install)
        defer { Task { await runtime.unload() } }

        let resolvedMode = KVModePolicy().resolvedMode(
            requestedMode: mode,
            intent: intent,
            modelID: install.id
        )
        session.modelID = install.id
        session.backend = .mlx
        session.cacheMode = mode
        session.intent = intent

        let compressor: CacheCompressor
        let artifactMode: CacheMode
        switch resolvedMode {
        case .turbo:
            compressor = TurboQuantCompressor()
            artifactMode = .turbo
            session.cacheMode = .raw
        case .triattention:
            compressor = PassthroughCompressor()
            artifactMode = .triattention
            session.cacheMode = .triattention
        case .raw, .automatic:
            compressor = PassthroughCompressor()
            artifactMode = .raw
            session.cacheMode = .raw
        }

        let service = CacheService(cacheStore: cacheStore)
        let result = try await service.buildArtifact(
            runtime: runtime,
            session: session,
            install: install,
            codec: MLXCacheSnapshotCodec(),
            compressor: compressor,
            artifactMode: artifactMode
        )

        print("artifact: \(result.artifact.id.uuidString)")
        print("requested_mode: \(mode.rawValue)")
        print("mode: \(result.artifact.manifest.cacheMode.rawValue)")
        print("intent: \(intent.rawValue)")
        print("size: \(ByteFormatting.string(for: result.artifact.sizeBytes))")
        if let rawSize = result.artifact.snapshotSizeBytes {
            print("snapshot: \(ByteFormatting.string(for: rawSize))")
        }
    }
}
