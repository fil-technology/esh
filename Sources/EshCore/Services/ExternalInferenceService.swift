import Foundation

public struct ExternalInferenceService: Sendable {
    private let modelStore: ModelStore
    private let sessionStore: SessionStore
    private let cacheStore: CacheStore
    private let backendResolver: @Sendable (ModelInstall) -> any InferenceBackend

    public init(
        modelStore: ModelStore,
        sessionStore: SessionStore,
        cacheStore: CacheStore,
        registry: InferenceBackendRegistry = .init()
    ) {
        self.modelStore = modelStore
        self.sessionStore = sessionStore
        self.cacheStore = cacheStore
        self.backendResolver = { registry.backend(for: $0) }
    }

    public init(
        modelStore: ModelStore,
        sessionStore: SessionStore,
        cacheStore: CacheStore,
        backendResolver: @escaping @Sendable (ModelInstall) -> any InferenceBackend
    ) {
        self.modelStore = modelStore
        self.sessionStore = sessionStore
        self.cacheStore = cacheStore
        self.backendResolver = backendResolver
    }

    public func infer(request: ExternalInferenceRequest) async throws -> ExternalInferenceResponse {
        guard request.messages.isEmpty == false else {
            throw StoreError.invalidManifest("External inference requires at least one message.")
        }
        guard request.schemaVersion == ExternalInferenceRequest.schemaVersion else {
            throw StoreError.invalidManifest("Unsupported infer schema version: \(request.schemaVersion)")
        }

        let install = try resolveInstall(request: request)
        let backend = backendResolver(install)
        let runtime = try await backend.loadRuntime(for: install)
        defer { Task { await runtime.unload() } }

        let session = try resolveSession(request: request, install: install)
        let integration: ExternalInferenceIntegration
        if let cacheArtifactID = request.cacheArtifactID {
            try await loadArtifactIfSupported(
                cacheArtifactID: cacheArtifactID,
                install: install,
                backend: backend,
                runtime: runtime
            )
            integration = ExternalInferenceIntegration(
                mode: "cache_load",
                cacheArtifactID: cacheArtifactID,
                cacheMode: request.cacheMode ?? session.cacheMode
            )
        } else {
            integration = ExternalInferenceIntegration(
                mode: "direct",
                cacheMode: request.cacheMode ?? session.cacheMode
            )
        }

        if request.cacheArtifactID == nil {
            try await runtime.prepare(session: session)
        }

        let stream = ChatService().streamReply(
            runtime: runtime,
            session: session,
            config: request.generation
        )
        var outputText = ""
        for try await chunk in stream {
            outputText += chunk
        }

        return ExternalInferenceResponse(
            modelID: install.id,
            backend: install.spec.backend,
            integration: integration,
            outputText: outputText,
            metrics: await runtime.metrics
        )
    }

    private func resolveInstall(request: ExternalInferenceRequest) throws -> ModelInstall {
        let installs = try modelStore.listInstalls()
        guard installs.isEmpty == false else {
            throw StoreError.notFound("No installed models found.")
        }

        if let model = request.model,
           let resolved = resolveInstall(identifier: model, installs: installs) {
            return resolved
        }

        if let cacheArtifactID = request.cacheArtifactID {
            let artifact = try cacheStore.loadArtifact(id: cacheArtifactID).0
            if let resolved = resolveInstall(identifier: artifact.manifest.modelID, installs: installs) {
                return resolved
            }
            throw StoreError.notFound("Cache artifact model \(artifact.manifest.modelID) is not installed.")
        }

        guard let first = installs.first else {
            throw StoreError.notFound("No installed models found.")
        }
        return first
    }

    private func resolveInstall(identifier: String, installs: [ModelInstall]) -> ModelInstall? {
        if let exact = installs.first(where: { $0.id == identifier }) {
            return exact
        }
        if let byRepo = installs.first(where: { $0.spec.source.reference == identifier }) {
            return byRepo
        }
        if let byDisplayName = installs.first(where: { $0.spec.displayName == identifier }) {
            return byDisplayName
        }

        let lowered = identifier.lowercased()
        return installs.first {
            $0.id.lowercased() == lowered ||
            $0.spec.source.reference.lowercased() == lowered ||
            $0.spec.displayName.lowercased() == lowered
        }
    }

    private func resolveSession(
        request: ExternalInferenceRequest,
        install: ModelInstall
    ) throws -> ChatSession {
        let sessionName = request.sessionName ?? "external"
        let cacheMode = request.cacheMode ?? .automatic
        let intent = request.intent ?? .chat
        let messages = request.messages.map { Message(role: $0.role, text: $0.text) }

        return ChatSession(
            name: sessionName,
            modelID: install.id,
            backend: install.spec.backend,
            cacheMode: cacheMode,
            intent: intent,
            autosaveEnabled: false,
            messages: messages
        )
    }

    private func loadArtifactIfSupported(
        cacheArtifactID: UUID,
        install: ModelInstall,
        backend: any InferenceBackend,
        runtime: any BackendRuntime
    ) async throws {
        guard install.spec.backend == .mlx else {
            throw StoreError.invalidManifest("Cache artifact load is currently supported for MLX models only.")
        }

        let compressor = artifactCompressor(for: cacheArtifactID)
        let service = CacheService(cacheStore: cacheStore)
        _ = try await service.loadArtifactForRuntime(
            id: cacheArtifactID,
            runtime: runtime,
            install: install,
            codec: MLXCacheSnapshotCodec(),
            compressor: compressor,
            checker: backend.makeCompatibilityChecker(for: install)
        )
    }

    private func artifactCompressor(for artifactID: UUID) -> CacheCompressor {
        if let artifact = try? cacheStore.loadArtifact(id: artifactID).0 {
            switch artifact.manifest.cacheMode {
            case .turbo:
                return TurboQuantCompressor()
            case .raw, .triattention, .automatic:
                return PassthroughCompressor()
            }
        }
        return PassthroughCompressor()
    }
}
