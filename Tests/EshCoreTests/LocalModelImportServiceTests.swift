import Foundation
import Testing
@testable import EshCore

@Suite
struct LocalModelImportServiceTests {
    @Test
    func importsMLXDirectoryWithoutRedownload() throws {
        let root = PersistenceRoot(rootURL: temporaryDirectory())
        let source = makeMLXModel(named: "Local MLX")
        let service = LocalModelImportService()

        let install = try service.importModel(from: source, id: "my-mlx", move: false, root: root)
        #expect(install.id == "my-mlx")
        #expect(install.spec.backend == .mlx)
        #expect(install.sizeBytes > 0)

        // Registered and listable; original source still present (copied, not moved).
        let installs = try FileModelStore(root: root).listInstalls()
        #expect(installs.contains { $0.id == "my-mlx" })
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("config.json").path))
    }

    @Test
    func importsGGUFFile() throws {
        let root = PersistenceRoot(rootURL: temporaryDirectory())
        let dir = temporaryDirectory()
        let gguf = dir.appendingPathComponent("tiny.Q4_K_M.gguf")
        try Data(repeating: 7, count: 2048).write(to: gguf)

        let install = try LocalModelImportService().importModel(from: gguf, root: root)
        #expect(install.spec.backend == .gguf)
        #expect(install.id == "tiny.Q4_K_M")
    }

    @Test
    func moveImportRemovesSource() throws {
        let root = PersistenceRoot(rootURL: temporaryDirectory())
        let source = makeMLXModel(named: "MoveMe")
        _ = try LocalModelImportService().importModel(from: source, id: "moved", move: true, root: root)
        #expect(!FileManager.default.fileExists(atPath: source.appendingPathComponent("config.json").path))
    }

    @Test
    func detectRejectsIncompleteDirectory() {
        let dir = temporaryDirectory()
        try? Data("{}".utf8).write(to: dir.appendingPathComponent("config.json")) // no safetensors
        #expect(LocalModelImportService().detect(at: dir) == nil)
    }

    @Test
    func scanRegistersValidModelsAndReportsOrphans() throws {
        let root = PersistenceRoot(rootURL: temporaryDirectory())
        let installs = root.modelsURL.appendingPathComponent("installs", isDirectory: true)
        try FileManager.default.createDirectory(at: installs, withIntermediateDirectories: true)

        // Valid unregistered model.
        let valid = installs.appendingPathComponent("discovered", isDirectory: true)
        try FileManager.default.createDirectory(at: valid, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: valid.appendingPathComponent("config.json"))
        try Data(repeating: 1, count: 256).write(to: valid.appendingPathComponent("model.safetensors"))

        // Orphaned partial download.
        let orphan = installs.appendingPathComponent("orphan", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 16).write(to: orphan.appendingPathComponent("model.safetensors.partial"))

        let service = LocalModelImportService()
        let result = try service.scanStore(root: root)
        #expect(result.registered.contains("discovered"))
        #expect(result.orphans.contains("orphan"))

        // Cleanup removes the orphan but never a registered model.
        let removed = try service.cleanupOrphans(root: root, ids: result.orphans + ["discovered"])
        #expect(removed == ["orphan"])
        #expect(FileManager.default.fileExists(atPath: valid.path))
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }

    // MARK: - Helpers

    private func makeMLXModel(named name: String) -> URL {
        let dir = temporaryDirectory().appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data("{\"architectures\":[\"Qwen2ForCausalLM\"]}".utf8).write(to: dir.appendingPathComponent("config.json"))
        try? Data(repeating: 3, count: 1024).write(to: dir.appendingPathComponent("model.safetensors"))
        try? Data("tok".utf8).write(to: dir.appendingPathComponent("tokenizer.json"))
        return dir
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
