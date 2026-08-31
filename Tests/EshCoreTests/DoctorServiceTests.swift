import Foundation
import Testing
@testable import EshCore

@Suite
struct DoctorServiceTests {
    @Test
    func reportIncludesStorageHostAndModels() {
        let root = PersistenceRoot(rootURL: temporaryDirectory())
        let report = DoctorService().report(root: root, version: "1.2.3")

        #expect(report.version == "1.2.3")
        #expect(!report.macOS.isEmpty)
        #expect(report.storage.status == "internal")
        #expect(report.models.installedCount == 0)
        #expect(report.stateRoot == root.stateRootURL.path)
        // Encodes to stable JSON.
        #expect(throws: Never.self) {
            _ = try JSONEncoder().encode(report)
        }
    }

    @Test
    func reportIsDegradedWhenAssetsVolumeUnavailable() throws {
        let state = temporaryDirectory()
        let externalParent = temporaryDirectory()
        let external = externalParent.appendingPathComponent("esh")
        let service = StorageService()
        let root = try service.setAssetsRoot(external.path, migrateExisting: false, root: PersistenceRoot(rootURL: state))
        try FileManager.default.removeItem(at: externalParent)

        let report = DoctorService().report(root: root, version: nil)
        #expect(report.status == "degraded")
        #expect(report.storage.status == "unavailable")
        #expect(report.storage.reason != nil)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
