import Foundation
import Testing
@testable import EshCore

@Suite
struct FileStoreTests {
    @Test
    func sessionStoreRoundTrip() throws {
        let root = PersistenceRoot(rootURL: temporaryDirectory())
        let store = FileSessionStore(root: root)
        let session = ChatSession(name: "demo")

        try store.save(session: session)
        let loaded = try store.loadSession(id: session.id)

        #expect(loaded.id == session.id)
        #expect(try store.listSessions().count == 1)
    }

    @Test
    func modelStoreSeparatesManifestAndInstallPaths() throws {
        let root = PersistenceRoot(rootURL: temporaryDirectory())
        let store = FileModelStore(root: root)
        let install = ModelInstall(
            id: "qwen-mlx",
            spec: ModelSpec(
                id: "qwen-mlx",
                displayName: "Qwen",
                backend: .mlx,
                source: ModelSource(kind: .huggingFace, reference: "Qwen/Qwen")
            ),
            installPath: root.modelsURL.appendingPathComponent("installs/qwen-mlx").path,
            sizeBytes: 42,
            backendFormat: "mlx"
        )
        let manifest = ModelManifest(install: install, files: ["weights.safetensors"])

        try store.save(manifest: manifest)

        let loaded = try store.loadManifest(id: "qwen-mlx")
        #expect(loaded.install.id == "qwen-mlx")
        #expect(FileManager.default.fileExists(atPath: root.modelsURL.appendingPathComponent("manifests/qwen-mlx.json").path))
        #expect(FileManager.default.fileExists(atPath: root.modelsURL.appendingPathComponent("installs/qwen-mlx").path))
    }

    @Test
    func cacheStoreRoundTrip() throws {
        let root = PersistenceRoot(rootURL: temporaryDirectory())
        let store = FileCacheStore(root: root)
        let manifest = CacheManifest(
            backend: .mlx,
            modelID: "qwen",
            architectureFingerprint: "abc",
            runtimeVersion: "1.0",
            cacheFormatVersion: "1",
            cacheMode: .turbo,
            sessionID: UUID(),
            sessionName: "default"
        )
        let artifact = CacheArtifact(
            manifest: manifest,
            artifactPath: "",
            sizeBytes: 0
        )

        try store.saveArtifact(artifact, payload: Data("payload".utf8))
        let loaded = try store.loadArtifact(id: artifact.id)

        #expect(loaded.0.id == artifact.id)
        #expect(String(decoding: loaded.1, as: UTF8.self) == "payload")
        #expect(try store.listArtifacts().count == 1)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
