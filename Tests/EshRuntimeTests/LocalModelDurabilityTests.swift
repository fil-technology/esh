import Foundation
import CryptoKit
import Testing
import EshCore
@testable import EshRuntime

// M10 #5 — model-install durability. Simulate interrupted lifecycles on disk and prove `reconcile()`
// reaches a consistent state, never reporting a half-installed model as usable.

private struct FixedProfile: DeviceProfileProviding {
    func currentProfile() -> DeviceProfile {
        DeviceProfile(platform: .iOS, physicalMemoryBytes: 8 << 30, availableMemoryBytes: 4 << 30,
                      availableMemoryKind: .processAvailable, availableStorageBytes: 8 << 30,
                      thermalState: .nominal, lowPowerModeEnabled: false, supportsAppleFoundationModels: true,
                      osVersion: "test", deviceModel: "test")
    }
}

@Suite
struct LocalModelDurabilityTests {
    private func tempRoot() -> PersistenceRoot {
        PersistenceRoot(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("esh-m10-\(UUID())"))
    }
    private func installsRoot(_ root: PersistenceRoot) -> URL {
        root.modelsURL.appendingPathComponent("installs", isDirectory: true)
    }
    private func modelDir(_ root: PersistenceRoot, _ id: String) -> URL {
        installsRoot(root).appendingPathComponent(id, isDirectory: true)
    }
    private func writeFile(_ url: URL, _ data: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    private func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    // record present but model file missing (killed before/after a bad finalize) → not usable, record dropped.
    @Test func brokenRecordIsRemoved() async throws {
        let root = tempRoot()
        let store = FileModelStore(root: root)
        let spec = ModelSpec(id: "m1", displayName: "M1", backend: .gguf, source: ModelSource(kind: .localPath, reference: "m1"))
        try store.save(manifest: ModelManifest(install: ModelInstall(id: "m1", spec: spec, installPath: modelDir(root, "m1").appendingPathComponent("model.gguf").path, sizeBytes: 10, backendFormat: "gguf"), files: ["model.gguf"]))
        let mgr = LocalModelManager(root: root, deviceProfileProvider: FixedProfile())
        #expect(await mgr.isInstalled("m1") == false)          // record without file is never usable
        let report = await mgr.reconcile()
        #expect(report.removedBrokenRecords.contains("m1"))
        #expect(await mgr.isInstalled("m1") == false)
        #expect(await mgr.reconcile().isConsistent)             // idempotent: second pass is clean
    }

    // model file present + verified, but record missing (killed mid-finalize) → recovered as installed.
    @Test func interruptedFinalizeIsRecovered() async throws {
        let root = tempRoot()
        let payload = Data((0..<4096).map { UInt8($0 % 251) })
        try writeFile(modelDir(root, "tiny").appendingPathComponent("model.gguf"), payload)
        let desc = LocalModelDescriptor(id: "tiny", displayName: "Tiny", sourceURL: URL(string: "http://x/y")!,
                                        repository: "t/t", license: "apache-2.0", expectedBytes: Int64(payload.count),
                                        sha256: sha(payload), quantization: "Q4_K_M", parameterCountB: 0.1,
                                        recommendedHardwareClass: "test")
        let mgr = LocalModelManager(root: root, deviceProfileProvider: FixedProfile())
        #expect(await mgr.isInstalled("tiny") == false)         // no record yet
        let report = await mgr.reconcile(catalog: [desc])
        #expect(report.recoveredRecords.contains("tiny"))
        #expect(await mgr.isInstalled("tiny"))                  // now a real, verified install
    }

    // orphan file that does NOT verify (wrong hash) and has no resume → removed, not recovered.
    @Test func unverifiableOrphanIsRemoved() async throws {
        let root = tempRoot()
        try writeFile(modelDir(root, "bad").appendingPathComponent("model.gguf"), Data([1, 2, 3, 4]))
        let desc = LocalModelDescriptor(id: "bad", displayName: "Bad", sourceURL: URL(string: "http://x/y")!,
                                        repository: "t/t", license: "apache-2.0", expectedBytes: 4,
                                        sha256: String(repeating: "0", count: 64), quantization: "Q4_K_M",
                                        parameterCountB: 0.1, recommendedHardwareClass: "test")
        let mgr = LocalModelManager(root: root, deviceProfileProvider: FixedProfile())
        let report = await mgr.reconcile(catalog: [desc])
        #expect(report.removedOrphanDirs.contains("bad"))
        #expect(FileManager.default.fileExists(atPath: modelDir(root, "bad").path) == false)
    }

    // a legitimate paused download (resume token, no model file) must be preserved by reconcile.
    @Test func pausedDownloadIsPreserved() async throws {
        let root = tempRoot()
        try writeFile(modelDir(root, "paused").appendingPathComponent("model.resume"), Data([9, 9, 9]))
        let mgr = LocalModelManager(root: root, deviceProfileProvider: FixedProfile())
        let report = await mgr.reconcile(catalog: [])
        #expect(report.isConsistent)   // nothing to repair
        #expect(FileManager.default.fileExists(atPath: modelDir(root, "paused").appendingPathComponent("model.resume").path))
    }

    // stale resume token left next to a fully installed model → cleared.
    @Test func staleResumeForInstalledIsCleared() async throws {
        let root = tempRoot()
        let store = FileModelStore(root: root)
        let payload = Data((0..<2048).map { UInt8($0 % 251) })
        let modelURL = modelDir(root, "m2").appendingPathComponent("model.gguf")
        try writeFile(modelURL, payload)
        try writeFile(modelDir(root, "m2").appendingPathComponent("model.resume"), Data([1]))
        let spec = ModelSpec(id: "m2", displayName: "M2", backend: .gguf, source: ModelSource(kind: .localPath, reference: "m2"))
        try store.save(manifest: ModelManifest(install: ModelInstall(id: "m2", spec: spec, installPath: modelURL.path, sizeBytes: Int64(payload.count), backendFormat: "gguf"), files: ["model.gguf"]))
        let mgr = LocalModelManager(root: root, deviceProfileProvider: FixedProfile())
        #expect(await mgr.isInstalled("m2"))
        let report = await mgr.reconcile(catalog: [])
        #expect(report.clearedStaleResume.contains("m2"))
        #expect(FileManager.default.fileExists(atPath: modelDir(root, "m2").appendingPathComponent("model.resume").path) == false)
        #expect(await mgr.isInstalled("m2"))   // still installed
    }
}
