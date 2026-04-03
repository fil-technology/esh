import Foundation
import EshCore

enum CacheBuildCommand {
    static func run(arguments: [String]) async throws {
        let sessionID = try requiredValue(flag: "--session", in: arguments)
        let modeValue = optionalValue(flag: "--mode", in: arguments) ?? "turbo"
        let modelID = optionalValue(flag: "--model", in: arguments)

        guard let uuid = UUID(uuidString: sessionID) else {
            throw StoreError.invalidManifest("Invalid session UUID: \(sessionID)")
        }
        guard let mode = CacheMode(rawValue: modeValue) else {
            throw StoreError.invalidManifest("Invalid cache mode: \(modeValue)")
        }

        let root = PersistenceRoot.default()
        let sessionStore = FileSessionStore(root: root)
        let modelStore = FileModelStore(root: root)
        let cacheStore = FileCacheStore(root: root)
        let session = try sessionStore.loadSession(id: uuid)
        let install = try resolveInstall(modelID: modelID, modelStore: modelStore)
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

    static func resolveInstall(modelID: String?, modelStore: FileModelStore) throws -> ModelInstall {
        let installs = try modelStore.listInstalls()
        if let modelID {
            guard let install = installs.first(where: { $0.id == modelID }) else {
                throw StoreError.notFound("Model \(modelID) is not installed.")
            }
            return install
        }
        guard let install = installs.first else {
            throw StoreError.notFound("No installed models found.")
        }
        return install
    }

    private static func requiredValue(flag: String, in arguments: [String]) throws -> String {
        guard let value = optionalValue(flag: flag, in: arguments) else {
            throw StoreError.invalidManifest("Missing required flag \(flag)")
        }
        return value
    }

    private static func optionalValue(flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }
}
