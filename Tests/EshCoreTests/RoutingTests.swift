import Foundation
import Testing
@testable import EshCore

@Suite
struct RoutingTests {
    @Test
    func validatorRejectsToolPathsOutsideWorkspace() throws {
        let workspace = temporaryDirectory()
        let validator = RoutingDecisionValidator(workspaceRootURL: workspace)
        let toolCall = RoutingToolCall(name: "read_file", arguments: ["path": "/etc/passwd"])

        #expect(throws: Error.self) {
            _ = try validator.validateToolCall(toolCall)
        }
    }

    @Test
    func lowConfidenceDecisionIsRejected() throws {
        let validator = RoutingDecisionValidator(
            workspaceRootURL: temporaryDirectory(),
            minimumConfidence: 0.7
        )
        let decision = RoutingDecision(
            action: .delegateToModel,
            targetModelRole: .main,
            confidence: 0.2
        )

        #expect(throws: Error.self) {
            try validator.validateDecision(decision)
        }
    }

    @Test
    func sequentialRoutingDelegatesCodeRequestToCodingModel() async throws {
        let root = PersistenceRoot(rootURL: temporaryDirectory())
        let modelStore = FileModelStore(root: root)
        let router = makeInstall(id: "router")
        let main = makeInstall(id: "main")
        let coding = makeInstall(id: "coding")
        try modelStore.save(manifest: ModelManifest(install: router, files: []))
        try modelStore.save(manifest: ModelManifest(install: main, files: []))
        try modelStore.save(manifest: ModelManifest(install: coding, files: []))

        let backend = RoutingTestBackend(outputs: [
            "router": """
            {"action":"delegate_to_model","targetModelRole":"coding","toolCall":null,"reason":"code request","confidence":0.91,"requiresLongContext":false,"requiresRepoAccess":false,"requiresInternet":false,"requiresFilesystem":false}
            """,
            "coding": "coding response"
        ])
        let service = ExternalInferenceService(
            modelStore: modelStore,
            sessionStore: FileSessionStore(root: root),
            cacheStore: FileCacheStore(root: root),
            backendResolver: { _ in backend },
            workspaceRootURL: root.rootURL
        )

        let response = try await service.infer(request: ExternalInferenceRequest(
            model: main.id,
            messages: [.init(role: .user, text: "Review this Swift function")],
            routing: RoutingConfiguration(
                enabled: true,
                mode: .sequential,
                routerModel: router.id,
                mainModel: main.id,
                codingModel: coding.id
            )
        ))

        #expect(response.outputText == "coding response")
        #expect(response.routing?.decision?.targetModelRole == .coding)
        #expect(response.routing?.selectedModel == "coding")
    }

    @Test
    func invalidRouterOutputFallsBackToMainModel() async throws {
        let root = PersistenceRoot(rootURL: temporaryDirectory())
        let modelStore = FileModelStore(root: root)
        let router = makeInstall(id: "router")
        let main = makeInstall(id: "main")
        try modelStore.save(manifest: ModelManifest(install: router, files: []))
        try modelStore.save(manifest: ModelManifest(install: main, files: []))

        let backend = RoutingTestBackend(outputs: [
            "router": "not json",
            "main": "main response"
        ])
        let service = ExternalInferenceService(
            modelStore: modelStore,
            sessionStore: FileSessionStore(root: root),
            cacheStore: FileCacheStore(root: root),
            backendResolver: { _ in backend },
            workspaceRootURL: root.rootURL
        )

        let response = try await service.infer(request: ExternalInferenceRequest(
            model: main.id,
            messages: [.init(role: .user, text: "Explain GGUF")],
            routing: RoutingConfiguration(
                enabled: true,
                mode: .sequential,
                routerModel: router.id,
                mainModel: main.id
            )
        ))

        #expect(response.outputText == "main response")
        #expect(response.routing?.selectedModel == "main")
        #expect(response.routing?.fallbackReason?.contains("router decision rejected") == true)
    }

    private func makeInstall(id: String) -> ModelInstall {
        ModelInstall(
            id: id,
            spec: ModelSpec(
                id: id,
                displayName: id,
                backend: .mlx,
                source: ModelSource(kind: .huggingFace, reference: "local/\(id)")
            ),
            installPath: temporaryDirectory().path,
            sizeBytes: 1,
            backendFormat: "mlx",
            runtimeVersion: "test"
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class RoutingTestBackend: InferenceBackend, @unchecked Sendable {
    let kind: BackendKind = .mlx
    let runtimeVersion: String = "test"
    let outputs: [String: String]

    init(outputs: [String: String]) {
        self.outputs = outputs
    }

    func loadRuntime(for install: ModelInstall) async throws -> BackendRuntime {
        RoutingTestRuntime(modelID: install.id, output: outputs[install.id] ?? "ok")
    }

    func makeCompatibilityChecker(for install: ModelInstall) -> CompatibilityChecking {
        RoutingTestCompatibilityChecker()
    }
}

private struct RoutingTestCompatibilityChecker: CompatibilityChecking, Sendable {
    func validate(manifest: CacheManifest) throws {}
}

private final class RoutingTestRuntime: BackendRuntime, @unchecked Sendable {
    let backend: BackendKind = .mlx
    let modelID: String
    let output: String
    var metrics: Metrics = .init()

    init(modelID: String, output: String) {
        self.modelID = modelID
        self.output = output
    }

    func prepare(session: ChatSession) async throws {}

    func generate(session: ChatSession, config: GenerationConfig) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(output)
            continuation.finish()
        }
    }

    func exportRuntimeCache() async throws -> CacheSnapshot {
        CacheSnapshot(format: "mlx", tensors: [])
    }

    func importRuntimeCache(_ snapshot: CacheSnapshot) async throws {}

    func validateCacheCompatibility(_ manifest: CacheManifest) async throws {}

    func unload() async {}
}
