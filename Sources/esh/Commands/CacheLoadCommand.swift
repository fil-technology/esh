import Foundation
import EshCore

enum CacheLoadCommand {
    static func run(arguments: [String]) async throws {
        let artifactValue = try CommandSupport.requiredValue(flag: "--artifact", in: arguments)
        let message = try CommandSupport.requiredValue(flag: "--message", in: arguments)
        let modelID = CommandSupport.optionalValue(flag: "--model", in: arguments)

        guard let artifactID = UUID(uuidString: artifactValue) else {
            throw StoreError.invalidManifest("Invalid artifact UUID: \(artifactValue)")
        }

        let root = PersistenceRoot.default()
        let modelStore = FileModelStore(root: root)
        let cacheStore = FileCacheStore(root: root)
        let sessionStore = FileSessionStore(root: root)
        let artifact = try cacheStore.loadArtifact(id: artifactID).0
        let baseSession = try sessionStore.loadSession(id: artifact.manifest.sessionID)
        let install = try CommandSupport.resolveInstall(
            identifier: modelID ?? artifact.manifest.modelID,
            modelStore: modelStore,
            preferredModelID: baseSession.modelID
        )
        guard install.spec.backend == .mlx else {
            throw StoreError.invalidManifest("Cache load currently supports MLX models only.")
        }
        let backend = MLXBackend()
        let runtime = try await backend.loadRuntime(for: install)
        defer { Task { await runtime.unload() } }

        let compressor = artifactCompressor(for: artifactID, cacheStore: cacheStore)
        let service = CacheService(cacheStore: cacheStore)
        let loadedArtifact = try await service.loadArtifactForRuntime(
            id: artifactID,
            runtime: runtime,
            install: install,
            codec: MLXCacheSnapshotCodec(),
            compressor: compressor,
            checker: backend.makeCompatibilityChecker(for: install)
        )

        var session = baseSession
        session.modelID = install.id
        session.backend = BackendKind.mlx
        session.messages.append(Message(role: .user, text: message))
        session.updatedAt = Date()
        let stream = ChatService().streamReply(runtime: runtime, session: session)
        var reply = ""
        for try await chunk in stream {
            reply += chunk
            print(chunk, terminator: "")
            fflush(stdout)
        }
        print("")

        let metrics = await runtime.metrics
        print("artifact: \(loadedArtifact.id.uuidString)")
        print("reply_chars: \(reply.count)")
        print("ttft_ms: \(metrics.ttftMilliseconds.map { String(format: "%.1f", $0) } ?? "-")")
        print("tok_s: \(metrics.tokensPerSecond.map { String(format: "%.2f", $0) } ?? "-")")
    }

    private static func artifactCompressor(for artifactID: UUID, cacheStore: FileCacheStore) -> CacheCompressor {
        if let artifact = try? cacheStore.loadArtifact(id: artifactID).0,
           artifact.manifest.cacheMode == .raw {
            return PassthroughCompressor()
        }
        return TurboQuantCompressor()
    }

}
