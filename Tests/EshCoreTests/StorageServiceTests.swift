import Foundation
import Testing
@testable import EshCore

@Suite
struct StorageServiceTests {
    // MARK: - PersistenceRoot routing

    @Test
    func stateAndAssetsRoutingIsClassifiedCorrectly() {
        let state = temporaryDirectory()
        let assets = temporaryDirectory()
        let root = PersistenceRoot(stateRootURL: state, assetsRootURL: assets)

        // Lightweight state stays internal.
        #expect(root.sessionsURL.path == state.appendingPathComponent("sessions").path)
        #expect(root.benchmarksURL.path == state.appendingPathComponent("benchmarks").path)
        // Heavy assets follow the assets root.
        #expect(root.modelsURL.path == assets.appendingPathComponent("models").path)
        #expect(root.cachesURL.path == assets.appendingPathComponent("caches").path)
        #expect(root.audioURL.path == assets.appendingPathComponent("audio").path)
        #expect(root.tempURL.path == assets.appendingPathComponent("tmp").path)
        #expect(root.usesExternalAssets)
    }

    @Test
    func defaultRootKeepsAssetsInternalForBackwardCompatibility() {
        let state = temporaryDirectory()
        let root = PersistenceRoot(rootURL: state)
        #expect(!root.usesExternalAssets)
        #expect(root.modelsURL.path == state.appendingPathComponent("models").path)
    }

    // MARK: - Availability lifecycle

    @Test
    func internalStorageIsAlwaysUsable() {
        let root = PersistenceRoot(rootURL: temporaryDirectory())
        let service = StorageService()
        #expect(service.availability(root: root).isUsable)
        #expect(throws: Never.self) { try service.ensureAssetsAvailable(root: root) }
    }

    @Test
    func setExternalPersistsAndReResolves() throws {
        let state = temporaryDirectory()
        let external = temporaryDirectory().appendingPathComponent("Ext Drive/esh") // path with a space
        let service = StorageService()
        let root = PersistenceRoot(rootURL: state)

        let newRoot = try service.setAssetsRoot(external.path, migrateExisting: false, root: root)
        #expect(newRoot.usesExternalAssets)
        #expect(service.availability(root: newRoot).isUsable)

        // A "restart" resolves the same assets root purely from the persisted internal config.
        let resolvedAssets = PersistenceRoot.resolveAssetsRoot(stateRoot: state)
        #expect(resolvedAssets.standardizedFileURL == external.standardizedFileURL)

        // storage.json lives on the internal state root and records the volume id.
        let config = StorageConfigStore(stateRootURL: state).load()
        #expect(config.usesExternalAssets)
        #expect(config.assetsVolumeID != nil)
    }

    @Test
    func disconnectedExternalVolumeIsUnavailableAndBlocksWrites() throws {
        let state = temporaryDirectory()
        let externalParent = temporaryDirectory()
        let external = externalParent.appendingPathComponent("esh")
        let service = StorageService()
        let root = PersistenceRoot(rootURL: state)

        let newRoot = try service.setAssetsRoot(external.path, migrateExisting: false, root: root)
        #expect(service.availability(root: newRoot).isUsable)

        // Simulate the volume being ejected.
        try FileManager.default.removeItem(at: externalParent)

        let availability = service.availability(root: newRoot)
        #expect(!availability.isUsable)
        if case .unavailable = availability {} else {
            Issue.record("Expected .unavailable, got \(availability)")
        }
        #expect(throws: StorageError.self) { try service.ensureAssetsAvailable(root: newRoot) }
    }

    @Test
    func differentVolumeMountedAtPathIsDetected() throws {
        let state = temporaryDirectory()
        let external = temporaryDirectory().appendingPathComponent("esh")
        let service = StorageService()
        let root = PersistenceRoot(rootURL: state)
        let newRoot = try service.setAssetsRoot(external.path, migrateExisting: false, root: root)

        // Replace the marker with a different id (a different volume mounted at the same path).
        let markerURL = StorageConfigStore.markerURL(inAssetsRoot: external)
        let foreign = StorageMarker(id: UUID().uuidString)
        try JSONCoding.encoder.encode(foreign).write(to: markerURL, options: .atomic)

        let availability = service.availability(root: newRoot)
        #expect(!availability.isUsable)
    }

    @Test
    func reconnectRestoresAvailabilityWithoutReinstall() throws {
        let state = temporaryDirectory()
        let externalParent = temporaryDirectory()
        let external = externalParent.appendingPathComponent("esh")
        let service = StorageService()
        let root = try service.setAssetsRoot(external.path, migrateExisting: false, root: PersistenceRoot(rootURL: state))

        let markerBefore = StorageConfigStore(stateRootURL: state).readMarker(inAssetsRoot: external)
        try FileManager.default.removeItem(at: externalParent)
        #expect(!service.availability(root: root).isUsable)

        // Reconnect: recreate the directory + original marker.
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try JSONCoding.encoder.encode(markerBefore).write(
            to: StorageConfigStore.markerURL(inAssetsRoot: external),
            options: .atomic
        )
        #expect(service.availability(root: root).isUsable)
    }

    // MARK: - Migration

    @Test
    func migrationMovesModelAssetsToNewRoot() throws {
        let state = temporaryDirectory()
        let root = PersistenceRoot(rootURL: state)
        // Seed a "model" on the internal assets root.
        let modelDir = root.modelsURL.appendingPathComponent("installs/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: modelDir.appendingPathComponent("model.safetensors"))

        let external = temporaryDirectory().appendingPathComponent("esh")
        let service = StorageService()
        let newRoot = try service.setAssetsRoot(external.path, migrateExisting: true, root: root)

        let movedFile = newRoot.modelsURL.appendingPathComponent("installs/demo/model.safetensors")
        #expect(FileManager.default.fileExists(atPath: movedFile.path))
        // Original assets location no longer holds the model.
        #expect(!FileManager.default.fileExists(atPath: modelDir.appendingPathComponent("model.safetensors").path))
    }

    @Test
    func reportComputesSizesForExistingAssets() throws {
        let state = temporaryDirectory()
        let root = PersistenceRoot(rootURL: state)
        let modelDir = root.modelsURL.appendingPathComponent("installs/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 4096).write(to: modelDir.appendingPathComponent("w.bin"))

        let report = StorageService().report(root: root)
        let models = report.locations.first { $0.storageClass == "models" }
        #expect(models?.exists == true)
        #expect((models?.sizeBytes ?? 0) >= 4096)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@Suite
struct PathResolvingTests {
    @Test
    func expandsTildeToHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(PathResolving.url(from: "~").standardizedFileURL == home.standardizedFileURL)
        #expect(PathResolving.url(from: "~/models").path == home.appendingPathComponent("models").path)
    }

    @Test
    func expandsHomeEnvVar() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(PathResolving.url(from: "$HOME/x").path == home.appendingPathComponent("x").path)
    }

    @Test
    func keepsAbsolutePathsAndHandlesSpaces() {
        #expect(PathResolving.url(from: "/Volumes/AI Drive/esh").path == "/Volumes/AI Drive/esh")
    }

    @Test
    func resolvesRelativeAgainstBase() {
        let base = URL(fileURLWithPath: "/tmp/base", isDirectory: true)
        #expect(PathResolving.url(from: "sub/dir", base: base).path == "/tmp/base/sub/dir")
    }
}
