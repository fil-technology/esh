import Foundation
import EshCore

enum CacheBuildCommand {
    static func run(arguments: [String], currentDirectoryURL: URL) async throws {
        let sessionIdentifier = try CommandSupport.requiredValue(flag: "--session", in: arguments)
        let modeValue = CommandSupport.optionalValue(flag: "--mode", in: arguments) ?? "auto"
        let intentValue = CommandSupport.optionalValue(flag: "--intent", in: arguments) ?? SessionIntent.chat.rawValue
        let modelID = CommandSupport.optionalValue(flag: "--model", in: arguments)
        let task = CommandSupport.optionalValue(flag: "--task", in: arguments)

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
        let workspaceRootURL = WorkspaceContextLocator(root: root).workspaceRootURL(from: currentDirectoryURL)
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

        let contextResolution = try resolveContextPackageIfNeeded(
            task: task,
            workspaceRootURL: workspaceRootURL,
            modelID: install.id,
            intent: intent,
            requestedMode: mode
        )
        let policyResolution = KVModePolicy().resolveMode(
            requestedMode: mode,
            intent: intent,
            modelID: install.id,
            contextPackage: contextResolution?.package
        )
        session.modelID = install.id
        session.backend = .mlx
        session.cacheMode = mode
        session.intent = intent

        let compressor: CacheCompressor
        let artifactMode: CacheMode
        switch policyResolution.mode {
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
            artifactMode: artifactMode,
            context: contextResolution.map {
                CacheBuildContext(
                    packageID: $0.package.id,
                    task: $0.package.manifest.task,
                    taskFingerprint: $0.package.manifest.taskFingerprint,
                    fileCount: $0.package.manifest.files.count,
                    reused: $0.reused,
                    policyReason: policyResolution.reason
                )
            }
        )

        print("artifact: \(result.artifact.id.uuidString)")
        print("requested_mode: \(mode.rawValue)")
        print("mode: \(result.artifact.manifest.cacheMode.rawValue)")
        print("intent: \(intent.rawValue)")
        print("policy: \(policyResolution.reason)")
        if let contextResolution {
            print("context_package: \(contextResolution.package.id.uuidString)")
            print("context_task: \(contextResolution.package.manifest.task)")
            print("context_files: \(contextResolution.package.manifest.files.count)")
            print("context_reused: \(contextResolution.reused ? "yes" : "no")")
        }
        print("size: \(ByteFormatting.string(for: result.artifact.sizeBytes))")
        if let rawSize = result.artifact.snapshotSizeBytes {
            print("snapshot: \(ByteFormatting.string(for: rawSize))")
        }
    }

    private static func resolveContextPackageIfNeeded(
        task: String?,
        workspaceRootURL: URL,
        modelID: String,
        intent: SessionIntent,
        requestedMode: CacheMode
    ) throws -> ContextPackageResolution? {
        guard let task, task.isEmpty == false else {
            return nil
        }
        let store = ContextStore(locator: WorkspaceContextLocator())
        guard let index = try? store.load(workspaceRootURL: workspaceRootURL) else {
            return nil
        }
        return try ContextPackageService().resolveBrief(
            task: task,
            index: index,
            workspaceRootURL: workspaceRootURL,
            limit: 5,
            snippetCount: 2,
            modelID: modelID,
            intent: intent,
            cacheMode: requestedMode
        )
    }
}
