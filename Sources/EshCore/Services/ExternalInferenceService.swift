import Foundation

public struct ExternalInferenceService: Sendable {
    private let modelStore: ModelStore
    private let sessionStore: SessionStore
    private let cacheStore: CacheStore
    private let backendResolver: @Sendable (ModelInstall) -> any InferenceBackend
    private let workspaceRootURL: URL

    public init(
        modelStore: ModelStore,
        sessionStore: SessionStore,
        cacheStore: CacheStore,
        registry: InferenceBackendRegistry = .init(),
        workspaceRootURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    ) {
        self.modelStore = modelStore
        self.sessionStore = sessionStore
        self.cacheStore = cacheStore
        self.backendResolver = { registry.backend(for: $0) }
        self.workspaceRootURL = workspaceRootURL.standardizedFileURL
    }

    public init(
        modelStore: ModelStore,
        sessionStore: SessionStore,
        cacheStore: CacheStore,
        backendResolver: @escaping @Sendable (ModelInstall) -> any InferenceBackend,
        workspaceRootURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    ) {
        self.modelStore = modelStore
        self.sessionStore = sessionStore
        self.cacheStore = cacheStore
        self.backendResolver = backendResolver
        self.workspaceRootURL = workspaceRootURL.standardizedFileURL
    }

    public func infer(request: ExternalInferenceRequest) async throws -> ExternalInferenceResponse {
        guard request.messages.isEmpty == false else {
            throw StoreError.invalidManifest("External inference requires at least one message.")
        }
        guard request.schemaVersion == ExternalInferenceRequest.schemaVersion else {
            throw StoreError.invalidManifest("Unsupported infer schema version: \(request.schemaVersion)")
        }

        if let routing = request.routing, routing.enabled, routing.mode != .disabled {
            return try await inferWithRouting(request: request, routing: routing)
        }

        let install = try resolveInstall(request: request)
        return try await inferDirect(request: request, install: install, routing: nil)
    }

    private func inferDirect(
        request: ExternalInferenceRequest,
        install: ModelInstall,
        routing: RoutingTrace?
    ) async throws -> ExternalInferenceResponse {
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
            metrics: await runtime.metrics,
            routing: routing
        )
    }

    private func inferWithRouting(
        request: ExternalInferenceRequest,
        routing: RoutingConfiguration
    ) async throws -> ExternalInferenceResponse {
        let effectiveMode = routing.mode == .parallel ? RoutingMode.sequential : routing.mode
        if effectiveMode == .single {
            let mainInstall = try resolveRoleInstall(role: .main, request: request, routing: routing)
            let trace = RoutingTrace(
                enabled: true,
                mode: .single,
                selectedModel: mainInstall.id,
                fallbackReason: routing.mode == .parallel ? "parallel routing is not supported yet; using single model" : nil
            )
            return try await inferDirect(request: request, install: mainInstall, routing: trace)
        }

        let routerInstall: ModelInstall
        do {
            routerInstall = try resolveRoleInstall(role: .router, request: request, routing: routing)
        } catch {
            return try await fallbackToMain(
                request: request,
                routing: routing,
                mode: effectiveMode,
                reason: "router model unavailable: \(error.localizedDescription)"
            )
        }

        let routerRequest = ExternalInferenceRequest(
            model: routerInstall.id,
            cacheMode: request.cacheMode,
            intent: .chat,
            messages: routerMessages(from: request),
            generation: GenerationConfig(
                maxTokens: routing.maxRouterTokens,
                temperature: routing.routerTemperature
            )
        )

        let start = Date()
        let routerResponse: ExternalInferenceResponse
        do {
            routerResponse = try await inferDirect(request: routerRequest, install: routerInstall, routing: nil)
        } catch {
            return try await fallbackToMain(
                request: request,
                routing: routing,
                mode: effectiveMode,
                reason: "router inference failed: \(error.localizedDescription)"
            )
        }

        let latency = Int(Date().timeIntervalSince(start) * 1000)
        let validator = RoutingDecisionValidator(
            workspaceRootURL: workspaceRootURL,
            minimumConfidence: routing.minimumConfidence
        )

        let decision: RoutingDecision
        do {
            decision = try validator.decodeDecision(from: routerResponse.outputText)
            try validator.validateDecision(decision)
        } catch {
            return try await fallbackToMain(
                request: request,
                routing: routing,
                mode: effectiveMode,
                reason: "router decision rejected: \(error.localizedDescription)",
                latency: latency
            )
        }

        switch decision.action {
        case .answerDirectly:
            if let answer = decision.answer, answer.isEmpty == false {
                return ExternalInferenceResponse(
                    modelID: routerInstall.id,
                    backend: routerInstall.spec.backend,
                    integration: ExternalInferenceIntegration(mode: "routing_direct"),
                    outputText: answer,
                    metrics: routerResponse.metrics,
                    routing: RoutingTrace(
                        enabled: true,
                        mode: effectiveMode,
                        routerModel: routerInstall.id,
                        selectedModel: routerInstall.id,
                        decision: decision,
                        routingLatencyMilliseconds: latency
                    )
                )
            }
            return try await fallbackToMain(
                request: request,
                routing: routing,
                mode: effectiveMode,
                reason: "answer_directly did not include an answer",
                latency: latency
            )
        case .askClarification:
            let question = decision.clarificationQuestion ?? decision.reason
            return ExternalInferenceResponse(
                modelID: routerInstall.id,
                backend: routerInstall.spec.backend,
                integration: ExternalInferenceIntegration(mode: "routing_clarification"),
                outputText: question.isEmpty ? "Could you clarify the request?" : question,
                metrics: routerResponse.metrics,
                routing: RoutingTrace(
                    enabled: true,
                    mode: effectiveMode,
                    routerModel: routerInstall.id,
                    selectedModel: routerInstall.id,
                    decision: decision,
                    routingLatencyMilliseconds: latency
                )
            )
        case .refuse:
            return ExternalInferenceResponse(
                modelID: routerInstall.id,
                backend: routerInstall.spec.backend,
                integration: ExternalInferenceIntegration(mode: "routing_refusal"),
                outputText: decision.reason.isEmpty ? "I cannot help with that request." : decision.reason,
                metrics: routerResponse.metrics,
                routing: RoutingTrace(
                    enabled: true,
                    mode: effectiveMode,
                    routerModel: routerInstall.id,
                    selectedModel: routerInstall.id,
                    decision: decision,
                    routingLatencyMilliseconds: latency
                )
            )
        case .delegateToModel:
            let selectedInstall = try resolveRoleInstall(role: decision.targetModelRole, request: request, routing: routing)
            let routedRequest = requestWithModel(selectedInstall.id, basedOn: request, temperature: routing.mainTemperature)
            return try await inferDirect(
                request: routedRequest,
                install: selectedInstall,
                routing: RoutingTrace(
                    enabled: true,
                    mode: effectiveMode,
                    routerModel: routerInstall.id,
                    selectedModel: selectedInstall.id,
                    decision: decision,
                    fallbackReason: routing.mode == .parallel ? "parallel routing is not supported yet; used sequential execution" : nil,
                    routingLatencyMilliseconds: latency
                )
            )
        case .callTool:
            guard let toolCall = decision.toolCall else {
                return try await fallbackToMain(
                    request: request,
                    routing: routing,
                    mode: effectiveMode,
                    reason: "call_tool did not include a toolCall",
                    latency: latency
                )
            }
            let validatedTool: ValidatedRoutingToolCall
            do {
                validatedTool = try validator.validateToolCall(toolCall)
            } catch {
                return try await fallbackToMain(
                    request: request,
                    routing: routing,
                    mode: effectiveMode,
                    reason: "tool call rejected: \(error.localizedDescription)",
                    latency: latency
                )
            }
            let toolResult = try executeTool(validatedTool)
            let selectedInstall = try resolveRoleInstall(role: decision.targetModelRole, request: request, routing: routing)
            let routedRequest = requestWithToolResult(
                toolResult,
                model: selectedInstall.id,
                basedOn: request,
                temperature: routing.mainTemperature
            )
            return try await inferDirect(
                request: routedRequest,
                install: selectedInstall,
                routing: RoutingTrace(
                    enabled: true,
                    mode: effectiveMode,
                    routerModel: routerInstall.id,
                    selectedModel: selectedInstall.id,
                    decision: decision,
                    fallbackReason: routing.mode == .parallel ? "parallel routing is not supported yet; used sequential execution" : nil,
                    routingLatencyMilliseconds: latency
                )
            )
        }
    }

    private func fallbackToMain(
        request: ExternalInferenceRequest,
        routing: RoutingConfiguration,
        mode: RoutingMode,
        reason: String,
        latency: Int? = nil
    ) async throws -> ExternalInferenceResponse {
        let mainInstall = try resolveRoleInstall(role: .main, request: request, routing: routing)
        let routedRequest = requestWithModel(mainInstall.id, basedOn: request, temperature: routing.mainTemperature)
        return try await inferDirect(
            request: routedRequest,
            install: mainInstall,
            routing: RoutingTrace(
                enabled: true,
                mode: mode,
                routerModel: routing.routerModel,
                selectedModel: mainInstall.id,
                fallbackReason: reason,
                routingLatencyMilliseconds: latency
            )
        )
    }

    private func routerMessages(from request: ExternalInferenceRequest) -> [ExternalInferenceMessage] {
        [
            ExternalInferenceMessage(role: .system, text: RoutingPrompt.system),
            ExternalInferenceMessage(
                role: .user,
                text: request.messages.map { "\($0.role.rawValue): \($0.text)" }.joined(separator: "\n")
            )
        ]
    }

    private func requestWithModel(
        _ modelID: String,
        basedOn request: ExternalInferenceRequest,
        temperature: Double
    ) -> ExternalInferenceRequest {
        var copy = request
        copy.model = modelID
        copy.routing = nil
        copy.generation.temperature = temperature
        return copy
    }

    private func requestWithToolResult(
        _ toolResult: String,
        model modelID: String,
        basedOn request: ExternalInferenceRequest,
        temperature: Double
    ) -> ExternalInferenceRequest {
        var copy = requestWithModel(modelID, basedOn: request, temperature: temperature)
        copy.messages.append(
            ExternalInferenceMessage(
                role: .system,
                text: "Validated local tool result:\n\(toolResult)"
            )
        )
        return copy
    }

    private func executeTool(_ toolCall: ValidatedRoutingToolCall) throws -> String {
        switch toolCall.name {
        case "read_file":
            guard let url = toolCall.resolvedFileURL else {
                throw StoreError.invalidManifest("read_file was missing a validated file URL.")
            }
            let text = try String(contentsOf: url, encoding: .utf8)
            return "read_file(\(url.path)):\n\(text)"
        default:
            throw StoreError.invalidManifest("Tool \(toolCall.name) is not implemented.")
        }
    }

    private func resolveRoleInstall(
        role: ModelRole,
        request: ExternalInferenceRequest,
        routing: RoutingConfiguration
    ) throws -> ModelInstall {
        if let modelID = routing.modelID(for: role),
           let install = try resolveInstall(identifier: modelID) {
            return install
        }
        if role == .main || role == .fallback {
            return try resolveInstall(request: request)
        }
        if role == .coding,
           let main = try? resolveRoleInstall(role: .main, request: request, routing: routing) {
            return main
        }
        throw StoreError.notFound("No installed model configured for routing role \(role.rawValue).")
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

    private func resolveInstall(identifier: String) throws -> ModelInstall? {
        try resolveInstall(identifier: identifier, installs: modelStore.listInstalls())
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
