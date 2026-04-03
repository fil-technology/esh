import Foundation
import EshCore

enum CacheBuildCommand {
    static func run(arguments: [String]) async throws {
        let sessionIdentifier = try CommandSupport.requiredValue(flag: "--session", in: arguments)
        let modeValue = CommandSupport.optionalValue(flag: "--mode", in: arguments) ?? "turbo"
        let modelID = CommandSupport.optionalValue(flag: "--model", in: arguments)

        guard let mode = CacheMode(rawValue: modeValue) else {
            throw StoreError.invalidManifest("Invalid cache mode: \(modeValue)")
        }

        let root = PersistenceRoot.default()
        let sessionStore = FileSessionStore(root: root)
        let modelStore = FileModelStore(root: root)
        let cacheStore = FileCacheStore(root: root)
        let session = try CommandSupport.resolveSession(identifier: sessionIdentifier, sessionStore: sessionStore)
        let install = try CommandSupport.resolveInstall(
            identifier: modelID,
            modelStore: modelStore,
            preferredModelID: session.modelID
        )
        let backend = MLXBackend()
        let runtime = try await backend.loadRuntime(for: install)
        defer { Task { await runtime.unload() } }

        let compressor: CacheCompressor = mode == .raw ? PassthroughCompressor() : TurboQuantCompressor()
        let service = CacheService(cacheStore: cacheStore)
        let result = try await service.buildArtifact(
            runtime: runtime,
            session: session,
            install: install,
            codec: MLXCacheSnapshotCodec(),
            compressor: compressor
        )

        print("artifact: \(result.artifact.id.uuidString)")
        print("mode: \(result.artifact.manifest.cacheMode.rawValue)")
        print("size: \(ByteFormatting.string(for: result.artifact.sizeBytes))")
        if let rawSize = result.artifact.snapshotSizeBytes {
            print("snapshot: \(ByteFormatting.string(for: rawSize))")
        }
    }
}
