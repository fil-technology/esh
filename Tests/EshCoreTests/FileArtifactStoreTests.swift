import Foundation
import Testing
@testable import EshCore

@Suite
struct FileArtifactStoreTests {
    private func makeStore() -> (FileArtifactStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("esh-artifact-tests-\(UUID().uuidString)", isDirectory: true)
        return (FileArtifactStore(rootURL: dir), dir)
    }

    @Test
    func savesBytesAndRecomputesFileMetadata() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8)
        let art = Artifact(kind: .svg, mimeType: "image/svg+xml", preview: .staticSandbox)
        let saved = try store.save(art, files: ["art.svg": svg])
        #expect(saved.files.count == 1)
        #expect(saved.files.first?.relativePath == "art.svg")
        #expect(saved.files.first?.byteSize == svg.count)
        #expect(saved.files.first?.sha256 == FileArtifactStore.sha256Hex(svg))

        let loaded = try store.load(id: saved.id)
        #expect(loaded?.kind == .svg)
        #expect(loaded?.files.first?.byteSize == svg.count)

        let bytes = try store.data(id: saved.id, file: "art.svg")
        #expect(bytes == svg)
    }

    @Test
    func metadataOnlyArtifactSavesWithoutFiles() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let art = Artifact(kind: .embedding, mimeType: "application/json",
                           metadata: ["dim": .int(768)])
        let saved = try store.save(art, files: [:])
        #expect(saved.files.isEmpty)
        let loaded = try store.load(id: saved.id)
        #expect(loaded?.kind == .embedding)
        #expect(loaded?.metadata["dim"] == .int(768))
    }

    @Test
    func rejectsPathTraversalOnSaveAndRead() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let art = Artifact(kind: .document, mimeType: "text/plain")
        #expect(throws: ArtifactStoreError.self) {
            _ = try store.save(art, files: ["../escape.txt": Data("x".utf8)])
        }
        // Absolute + parent traversal are both rejected by the sanitizer.
        #expect(FileArtifactStore.sanitizedRelativePath("../a") == nil)
        #expect(FileArtifactStore.sanitizedRelativePath("/etc/passwd") == nil)
        #expect(FileArtifactStore.sanitizedRelativePath("a/../b") == nil)
        #expect(FileArtifactStore.sanitizedRelativePath("sub/dir/file.txt") == "sub/dir/file.txt")
    }

    @Test
    func listAndDelete() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try store.save(Artifact(kind: .svg, mimeType: "image/svg+xml"), files: ["a.svg": Data("a".utf8)])
        _ = try store.save(Artifact(kind: .image, mimeType: "image/png"), files: ["b.png": Data("b".utf8)])
        #expect(try store.list().count == 2)
        try store.delete(id: a.id)
        #expect(try store.load(id: a.id) == nil)
        #expect(try store.list().count == 1)
    }

    @Test
    func persistenceRootExposesArtifactsURL() {
        let root = PersistenceRoot(rootURL: URL(fileURLWithPath: "/tmp/esh-x"))
        #expect(root.artifactsURL.lastPathComponent == "artifacts")
        #expect(root.artifactsURL.deletingLastPathComponent().path == root.assetsRootURL.path)
    }
}
