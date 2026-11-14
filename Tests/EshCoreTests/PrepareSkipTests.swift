import Foundation
import Testing
@testable import EshCore

// The one-shot MLX runtime's `prepare` is a second model load; request paths must skip it when the runtime
// declares it redundant, and keep calling it for every other runtime.
@Suite struct PrepareSkipTests {
    @Test func redundantPrepareIsSkipped() async throws {
        let counter = PrepareCounter()
        let response = try await infer(redundant: true, counter: counter)
        #expect(response.outputText == "ok")
        #expect(counter.value == 0)
    }

    @Test func otherRuntimesStillPrepare() async throws {
        let counter = PrepareCounter()
        _ = try await infer(redundant: false, counter: counter)
        #expect(counter.value == 1)
    }

    private func infer(redundant: Bool, counter: PrepareCounter) async throws -> ExternalInferenceResponse {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let root = PersistenceRoot(rootURL: dir)
        let store = FileModelStore(root: root)
        let install = ModelInstall(
            id: "m", spec: ModelSpec(id: "m", displayName: "m", backend: .mlx,
                                     source: ModelSource(kind: .huggingFace, reference: "local/m")),
            installPath: dir.path, sizeBytes: 1, backendFormat: "mlx", runtimeVersion: "test")
        try store.save(manifest: ModelManifest(install: install, files: []))
        let backend = SkipTestBackend(redundant: redundant, counter: counter)
        let service = ExternalInferenceService(
            modelStore: store, sessionStore: FileSessionStore(root: root), cacheStore: FileCacheStore(root: root),
            backendResolver: { _ in backend }, workspaceRootURL: dir)
        return try await service.infer(request: ExternalInferenceRequest(model: "m", messages: [.init(role: .user, text: "hi")]))
    }
}

private final class PrepareCounter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func inc() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

private final class SkipTestBackend: InferenceBackend, @unchecked Sendable {
    let kind: BackendKind = .mlx
    let runtimeVersion = "test"
    let redundant: Bool
    let counter: PrepareCounter
    init(redundant: Bool, counter: PrepareCounter) { self.redundant = redundant; self.counter = counter }
    func loadRuntime(for install: ModelInstall) async throws -> BackendRuntime {
        SkipTestRuntime(modelID: install.id, redundant: redundant, counter: counter)
    }
    func makeCompatibilityChecker(for install: ModelInstall) -> CompatibilityChecking { SkipChecker() }
}

private struct SkipChecker: CompatibilityChecking, Sendable { func validate(manifest: CacheManifest) throws {} }

private final class SkipTestRuntime: BackendRuntime, @unchecked Sendable {
    let backend: BackendKind = .mlx
    let modelID: String
    let redundant: Bool
    let counter: PrepareCounter
    var metrics: Metrics = .init()
    var prepareBeforeGenerateIsRedundant: Bool { redundant }
    init(modelID: String, redundant: Bool, counter: PrepareCounter) {
        self.modelID = modelID; self.redundant = redundant; self.counter = counter
    }
    func prepare(session: ChatSession) async throws { counter.inc() }
    func generate(session: ChatSession, config: GenerationConfig) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.yield("ok"); $0.finish() }
    }
    func exportRuntimeCache() async throws -> CacheSnapshot { CacheSnapshot(format: "mlx", tensors: []) }
    func importRuntimeCache(_ snapshot: CacheSnapshot) async throws {}
    func validateCacheCompatibility(_ manifest: CacheManifest) async throws {}
    func unload() async {}
}
