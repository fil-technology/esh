import Foundation
import CryptoKit
import Testing
import EshCore
@testable import EshRuntime

// RC follow-up — background/relaunch model-download behavior that does NOT require a live OS transfer:
// persisted download state survives runtime recreation, a transfer that completed while suspended is
// verified + installed on the next runtime, and a corrupt completed transfer never becomes installed.
// (True OS-managed background continuation is device-only; see docs/PRODUCTION_READINESS.md.)

@Suite
struct BackgroundDownloadTests {
    private func tempRoot() -> PersistenceRoot {
        PersistenceRoot(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("esh-bg-\(UUID())"))
    }
    private func installsRoot(_ r: PersistenceRoot) -> URL { r.modelsURL.appendingPathComponent("installs", isDirectory: true) }
    private func modelDir(_ r: PersistenceRoot, _ id: String) -> URL { installsRoot(r).appendingPathComponent(id, isDirectory: true) }
    private func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
    private func mgr(_ r: PersistenceRoot) -> LocalModelManager { LocalModelManager(root: r) }

    /// Write a persisted download record (as the coordinator would) + optional staged file, simulating an
    /// interrupted/completed background transfer left by a PREVIOUS runtime.
    @discardableResult
    private func writeRecord(_ r: PersistenceRoot, id: String, phase: PendingDownload.Phase,
                             staged: Data?, expectedBytes: Int64, sha256: String, progress: Double = 0) throws -> URL {
        let dir = modelDir(r, id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var stagedPath: String?
        if let staged {
            let s = dir.appendingPathComponent("model.download")
            try staged.write(to: s); stagedPath = s.path
        }
        let rec = PendingDownload(modelID: id, sourceURL: URL(string: "https://huggingface.co/x.gguf")!,
                                  expectedBytes: expectedBytes, sha256: sha256, phase: phase,
                                  stagedPath: stagedPath, lastProgress: progress, reason: phase == .failed ? "boom" : nil,
                                  updatedAt: Date())
        try JSONEncoder().encode(rec).write(to: dir.appendingPathComponent("download.json"))
        return dir
    }

    private func desc(_ id: String) -> LocalModelDescriptor {
        LocalModelDescriptor(id: id, displayName: id, sourceURL: URL(string: "https://huggingface.co/x.gguf")!,
                             repository: "t/t", license: "apache-2.0", expectedBytes: 0, sha256: "",
                             quantization: "Q4_K_M", parameterCountB: 0.1, recommendedHardwareClass: "test")
    }

    // Completion-while-suspended: a NEW runtime finalizes a verified staged transfer on reconcile().
    @Test func completedWhileSuspendedIsFinalizedByNewRuntime() async throws {
        let root = tempRoot()
        let payload = Data((0..<8192).map { UInt8($0 % 251) })
        try writeRecord(root, id: "bg", phase: .downloaded, staged: payload,
                        expectedBytes: Int64(payload.count), sha256: sha(payload), progress: 1)
        // Fresh runtime (host did not retain the original object).
        let m = mgr(root)
        #expect(await m.isInstalled("bg") == false)             // not yet — pending verification
        let report = await m.reconcile(catalog: [])             // relaunch reconcile
        #expect(report.finalizedPendingDownloads.contains("bg"))
        #expect(await m.isInstalled("bg"))                      // verified + installed by the new runtime
    }

    // A completed transfer that fails verification must NEVER become installed; the corrupt state is cleared.
    @Test func corruptCompletedTransferNeverInstalls() async throws {
        let root = tempRoot()
        let payload = Data((0..<8192).map { UInt8($0 % 251) })
        // record claims a sha that does not match the staged bytes
        try writeRecord(root, id: "bad", phase: .downloaded, staged: payload,
                        expectedBytes: Int64(payload.count), sha256: String(repeating: "0", count: 64), progress: 1)
        let m = mgr(root)
        let report = await m.reconcile(catalog: [])
        #expect(report.finalizedPendingDownloads.contains("bad") == false)
        #expect(await m.isInstalled("bad") == false)
        #expect(FileManager.default.fileExists(atPath: modelDir(root, "bad").appendingPathComponent("model.download").path) == false)
    }

    // Public state is coherent across runtime recreation from the persisted record.
    @Test func stateReconstructedAcrossRuntimes() async throws {
        let root = tempRoot()
        try writeRecord(root, id: "dl", phase: .downloading, staged: nil, expectedBytes: 100, sha256: "x", progress: 0.4)
        #expect(await mgr(root).state(for: desc("dl")) == .downloading(progress: 0.4))

        try writeRecord(root, id: "ve", phase: .downloaded, staged: Data([1, 2, 3]), expectedBytes: 3, sha256: "x")
        #expect(await mgr(root).state(for: desc("ve")) == .verifying)

        try writeRecord(root, id: "fa", phase: .failed, staged: nil, expectedBytes: 1, sha256: "x")
        if case .failed = await mgr(root).state(for: desc("fa")) {} else { Issue.record("expected .failed") }
    }

    // An in-flight/failed download record is not treated as an orphan and is preserved by reconcile.
    @Test func inFlightRecordSurvivesReconcile() async throws {
        let root = tempRoot()
        try writeRecord(root, id: "keep", phase: .downloading, staged: nil, expectedBytes: 100, sha256: "x", progress: 0.2)
        let report = await mgr(root).reconcile(catalog: [])
        #expect(report.isConsistent)
        #expect(FileManager.default.fileExists(atPath: modelDir(root, "keep").appendingPathComponent("download.json").path))
    }

    // The default production download config on iOS is a true background session (not default/ephemeral).
    @Test func iOSDefaultConfigIsBackgroundCapable() {
        let config = LocalModelManager.defaultDownloadConfiguration()
        #if os(iOS)
        #expect(config.identifier == ModelDownloadCoordinator.backgroundIdentifier)   // background(withIdentifier:)
        #expect(config.sessionSendsLaunchEvents == true)
        #else
        #expect(config.identifier == nil)   // foreground/ephemeral off-device (CLI/tests)
        #endif
    }
}
