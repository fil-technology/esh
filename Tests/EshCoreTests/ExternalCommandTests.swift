import Foundation
import Testing
@testable import EshCore

@Suite
struct ExternalCommandTests {
    @Test
    func capabilitiesAdvertiseDirectAndCacheSupportPerBackend() throws {
        let root = PersistenceRoot(rootURL: temporaryDirectory())
        let modelStore = FileModelStore(root: root)

        try modelStore.save(manifest: ModelManifest(install: ModelInstall(
            id: "mlx-model",
            spec: ModelSpec(
                id: "mlx-model",
                displayName: "MLX Demo",
                backend: .mlx,
                source: ModelSource(kind: .huggingFace, reference: "mlx-community/demo")
            ),
            installPath: root.modelsURL.appendingPathComponent("installs/mlx-model").path,
            sizeBytes: 1,
            backendFormat: "mlx",
            runtimeVersion: "mlx-runtime"
        ), files: ["weights.safetensors"]))
        try modelStore.save(manifest: ModelManifest(install: ModelInstall(
            id: "gguf-model",
            spec: ModelSpec(
                id: "gguf-model",
                displayName: "GGUF Demo",
                backend: .gguf,
                source: ModelSource(kind: .huggingFace, reference: "bartowski/demo-GGUF")
            ),
            installPath: root.modelsURL.appendingPathComponent("installs/gguf-model").path,
            sizeBytes: 1,
            backendFormat: "gguf",
            runtimeVersion: "llama-runtime"
        ), files: ["model.gguf"]))

        let response = try ExternalCapabilitiesService(modelStore: modelStore)
            .describe(toolVersion: "1.2.3")

        #expect(response.schemaVersion == ExternalCapabilitiesResponse.schemaVersion)
        #expect(response.commands.map(\.name) == ["infer", "capabilities"])
        let mlx = try #require(response.backends.first(where: { $0.backend == .mlx }))
        #expect(mlx.supportsDirectInference)
        #expect(mlx.supportsCacheBuild)
        #expect(mlx.supportsCacheLoad)
        #expect(mlx.supportedFeatures.contains(.thinkingMode))
        #expect(mlx.supportedFeatures.contains(.kvCacheQuantization))
        #expect(mlx.unavailableFeatures.contains { $0.feature == .responseFormatJsonSchema })
        let gguf = try #require(response.backends.first(where: { $0.backend == .gguf }))
        #expect(gguf.supportsDirectInference)
        #expect(gguf.supportsCacheBuild == false)
        #expect(gguf.supportsCacheLoad == false)
        let ggufModel = try #require(response.installedModels.first(where: { $0.id == "gguf-model" }))
        #expect(ggufModel.supportsDirectInference)
        #expect(ggufModel.supportsCacheLoad == false)
    }

    @Test
    func inferUsesDirectPathWithoutArtifactAndCachePathWithArtifact() async throws {
        let root = PersistenceRoot(rootURL: temporaryDirectory())
        let modelStore = FileModelStore(root: root)
        let sessionStore = FileSessionStore(root: root)
        let cacheStore = FileCacheStore(root: root)

        let install = ModelInstall(
            id: "mlx-model",
            spec: ModelSpec(
                id: "mlx-model",
                displayName: "MLX Demo",
                backend: .mlx,
                source: ModelSource(kind: .huggingFace, reference: "mlx-community/demo"),
                tokenizerID: "demo-tokenizer",
                architectureFingerprint: "arch-1"
            ),
            installPath: root.modelsURL.appendingPathComponent("installs/mlx-model").path,
            sizeBytes: 1,
            backendFormat: "mlx",
            runtimeVersion: "mlx-runtime"
        )
        try modelStore.save(manifest: ModelManifest(install: install, files: ["weights.safetensors"]))

        let artifactID = UUID()
        let manifest = CacheManifest(
            backend: .mlx,
            modelID: install.id,
            tokenizerID: install.spec.tokenizerID,
            architectureFingerprint: "arch-1",
            runtimeVersion: "mlx-runtime",
            cacheFormatVersion: MLXCacheSnapshotCodec().formatVersion,
            compressorVersion: PassthroughCompressor().version,
            cacheMode: .raw,
            sessionID: UUID(),
            sessionName: "artifact-session"
        )
        try cacheStore.saveArtifact(
            CacheArtifact(id: artifactID, manifest: manifest, artifactPath: "", sizeBytes: 0),
            payload: try MLXCacheSnapshotCodec().encode(
                snapshot: CacheSnapshot(format: "mlx", tensors: [])
            )
        )

        let backend = TestInferenceBackend()
        let service = ExternalInferenceService(
            modelStore: modelStore,
            sessionStore: sessionStore,
            cacheStore: cacheStore,
            backendResolver: { _ in backend }
        )

        let direct = try await service.infer(request: ExternalInferenceRequest(
            model: install.id,
            messages: [.init(role: .user, text: "Hello")]
        ))
        #expect(direct.integration.mode == "direct")
        #expect(direct.outputText == "ok")
        let directRuntime = try #require(backend.lastRuntime)
        #expect(directRuntime.prepareCount == 1)
        #expect(directRuntime.importCount == 0)

        let cached = try await service.infer(request: ExternalInferenceRequest(
            model: install.id,
            cacheArtifactID: artifactID,
            messages: [.init(role: .user, text: "Hello again")]
        ))
        #expect(cached.integration.mode == "cache_load")
        let cachedRuntime = try #require(backend.lastRuntime)
        #expect(cachedRuntime.importCount == 1)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class TestInferenceBackend: InferenceBackend, @unchecked Sendable {
    let kind: BackendKind = .mlx
    let runtimeVersion: String = "test-runtime"
    private(set) var lastRuntime: TestBackendRuntime?

    func loadRuntime(for install: ModelInstall) async throws -> BackendRuntime {
        let runtime = TestBackendRuntime(modelID: install.id)
        lastRuntime = runtime
        return runtime
    }

    func makeCompatibilityChecker(for install: ModelInstall) -> CompatibilityChecking {
        TestCompatibilityChecker(expectedModelID: install.id)
    }
}

private struct TestCompatibilityChecker: CompatibilityChecking, Sendable {
    let expectedModelID: String

    func validate(manifest: CacheManifest) throws {
        #expect(manifest.modelID == expectedModelID)
    }
}

private final class TestBackendRuntime: BackendRuntime, @unchecked Sendable {
    let backend: BackendKind = .mlx
    let modelID: String
    var metrics: Metrics = .init(ttftMilliseconds: 5)
    private(set) var prepareCount = 0
    private(set) var importCount = 0

    init(modelID: String) {
        self.modelID = modelID
    }

    func prepare(session: ChatSession) async throws {
        prepareCount += 1
    }

    func generate(session: ChatSession, config: GenerationConfig) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("ok")
            continuation.finish()
        }
    }

    func exportRuntimeCache() async throws -> CacheSnapshot {
        CacheSnapshot(format: "mlx", tensors: [])
    }

    func importRuntimeCache(_ snapshot: CacheSnapshot) async throws {
        importCount += 1
    }

    func validateCacheCompatibility(_ manifest: CacheManifest) async throws {}

    func unload() async {}
}
