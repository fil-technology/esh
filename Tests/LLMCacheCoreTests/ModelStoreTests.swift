import Foundation
import Testing
@testable import LLMCacheCore

@Suite
struct ModelStoreTests {
    @Test
    func prepareInstallDirectoryReturnsStableFolder() throws {
        let root = PersistenceRoot(rootURL: temporaryDirectory())
        let store = FileModelStore(root: root)

        let url = try store.prepareInstallDirectory(id: "demo-model")

        #expect(url.lastPathComponent == "demo-model")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
