import Foundation
import Network
import Testing
import EshCore
@testable import EshRuntime

// A tiny localhost HTTP server for deterministic download tests (no external network).
private final class TestHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    let port: UInt16
    private let body: Data
    private let contentLengthOverride: Int?   // if set, advertise this Content-Length (to force size mismatch)

    init(body: Data, contentLengthOverride: Int? = nil) throws {
        self.body = body
        self.contentLengthOverride = contentLengthOverride
        let params = NWParameters.tcp
        listener = try NWListener(using: params, on: .any)
        listener.newConnectionHandler = { [body, contentLengthOverride] conn in
            conn.start(queue: .global())
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                let len = contentLengthOverride ?? body.count
                let header = "HTTP/1.1 200 OK\r\nContent-Length: \(len)\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n"
                var out = Data(header.utf8); out.append(body)
                conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        let sem = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { sem.signal() } }
        listener.start(queue: .global())
        sem.wait()
        port = listener.port!.rawValue
    }
    func url(path: String = "/model.gguf") -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
    func stop() { listener.cancel() }
}

private struct FixedProfile: DeviceProfileProviding {
    let storage: UInt64?
    let physical: UInt64
    func currentProfile() -> DeviceProfile {
        DeviceProfile(platform: .iOS, physicalMemoryBytes: physical, availableMemoryBytes: physical / 2,
                      availableMemoryKind: .processAvailable, availableStorageBytes: storage,
                      thermalState: .nominal, lowPowerModeEnabled: false, supportsAppleFoundationModels: true,
                      osVersion: "test", deviceModel: "test")
    }
}

private func tempRoot() -> PersistenceRoot {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("esh-m8-\(UUID().uuidString)")
    return PersistenceRoot(rootURL: dir)
}

private func sha256Hex(_ d: Data) -> String {
    // reuse the manager's file hasher via a temp file to keep one implementation under test
    let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? d.write(to: u); defer { try? FileManager.default.removeItem(at: u) }
    return (try? LocalModelManager.sha256Hex(of: u)) ?? ""
}

private func descriptor(url: URL, bytes: Int64, sha: String, params: Double = 0.5) -> LocalModelDescriptor {
    LocalModelDescriptor(id: "test-model", displayName: "Test", sourceURL: url, repository: "test/repo",
                         license: "apache-2.0", expectedBytes: bytes, sha256: sha, quantization: "Q4_K_M",
                         parameterCountB: params, recommendedHardwareClass: "test")
}

@Suite
struct LocalModelManagerTests {

    @Test func catalogIsDataDrivenAndCurated() {
        #expect(LocalModelCatalog.models.count >= 2)
        #expect(LocalModelCatalog.descriptor(id: "qwen2.5-1.5b-instruct-q4km")?.sha256 == "1adf0b11065d8ad2e8123ea110d1ec956dab4ab038eab665614adba04b6c3370")
        #expect(LocalModelCatalog.models.allSatisfy { $0.license == "apache-2.0" && !$0.sha256.isEmpty && $0.expectedBytes > 0 })
    }

    // MARK: non-curated (Hugging Face / side-loaded) installs (rc.27)

    /// Writes an HF-style install (manifest + real-named weight file) directly to the store, as
    /// `HuggingFaceModelDownloader` would. `staleDirLocalPath` reproduces the old bug where a GGUF spec's
    /// `localPath` pointed at the install directory instead of the weight file.
    @discardableResult
    private func writeHFInstall(root: PersistenceRoot, id: String, repo: String, fileName: String,
                                bytes: Int, staleDirLocalPath: Bool) throws -> URL {
        let store = FileModelStore(root: root)
        let dir = root.modelsURL.appendingPathComponent("installs").appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent(fileName)
        try Data(repeating: 7, count: bytes).write(to: fileURL)
        let spec = ModelSpec(id: id, displayName: repo, backend: .gguf,
                             source: ModelSource(kind: .huggingFace, reference: repo),
                             localPath: staleDirLocalPath ? dir.path : fileURL.path,
                             baseModelID: repo, variant: "Q8_0")
        let install = ModelInstall(id: id, spec: spec, installPath: dir.path, sizeBytes: Int64(bytes),
                                   backendFormat: "gguf", runtimeVersion: nil,
                                   huggingFace: HuggingFaceInstallProvenance(repoID: repo, revision: "abc",
                                       files: [fileName], format: "gguf", quantization: "Q8_0"))
        try store.save(manifest: ModelManifest(install: install, files: [fileName]))
        return fileURL
    }

    @Test func statusesSurfacesNonCuratedHFInstall() async throws {
        let root = tempRoot()
        try writeHFInstall(root: root, id: "mradermacher--llama-3-8b-web-gguf",
                           repo: "mradermacher/Llama-3-8B-Web-GGUF",
                           fileName: "Llama-3-8B-Web.Q8_0.gguf", bytes: 4096, staleDirLocalPath: false)
        let mgr = LocalModelManager(root: root, deviceProfileProvider: FixedProfile(storage: 8 << 30, physical: 16 << 30))
        let statuses = await mgr.statuses()
        let hf = statuses.first { $0.descriptor.id == "mradermacher--llama-3-8b-web-gguf" }
        #expect(hf != nil)                                   // was invisible before the fix
        #expect(hf?.state == .installed)
        #expect(hf?.descriptor.repository == "mradermacher/Llama-3-8B-Web-GGUF")
        #expect(hf?.descriptor.quantization == "Q8_0")
        #expect(await mgr.isInstalled("mradermacher--llama-3-8b-web-gguf"))
        // Curated models still listed.
        #expect(statuses.contains { $0.descriptor.id == "qwen2.5-1.5b-instruct-q4km" })
    }

    @Test func reconcileDoesNotDeleteNonCuratedHFInstall() async throws {
        let root = tempRoot()
        let weight = try writeHFInstall(root: root, id: "owner--model-gguf", repo: "owner/model-GGUF",
                                        fileName: "model.Q8_0.gguf", bytes: 4096, staleDirLocalPath: false)
        let mgr = LocalModelManager(root: root, deviceProfileProvider: FixedProfile(storage: 8 << 30, physical: 16 << 30))
        let report = await mgr.reconcile()
        #expect(!report.removedBrokenRecords.contains("owner--model-gguf"))   // regression: was deleted (data loss)
        #expect(FileManager.default.fileExists(atPath: weight.path))          // 8.5 GB file would have been removed
        #expect(await mgr.isInstalled("owner--model-gguf"))
    }

    @Test func reconcileRepairsStaleDirectoryLocalPath() async throws {
        let root = tempRoot()
        let weight = try writeHFInstall(root: root, id: "owner--stale-gguf", repo: "owner/stale-GGUF",
                                        fileName: "stale.Q8_0.gguf", bytes: 4096, staleDirLocalPath: true)
        let mgr = LocalModelManager(root: root, deviceProfileProvider: FixedProfile(storage: 8 << 30, physical: 16 << 30))
        let report = await mgr.reconcile()
        #expect(report.repairedModelPaths.contains("owner--stale-gguf"))
        let manifest = try FileModelStore(root: root).loadManifest(id: "owner--stale-gguf")
        #expect(manifest.install.spec.localPath == weight.path)              // now points at the weight FILE
    }

    @Test func installPlanRejectsInsufficientStorage() async {
        let mgr = LocalModelManager(root: tempRoot(), deviceProfileProvider: FixedProfile(storage: 10 * 1024 * 1024, physical: 8 << 30))
        let d = descriptor(url: URL(string: "http://127.0.0.1:1/x")!, bytes: 986_048_768, sha: "00")
        let plan = await mgr.installPlan(for: d)
        #expect(plan.storageSufficient == false)
        #expect(plan.suitable == false)
    }

    @Test func installPlanSuitableWhenExFATImportantUsageIsZeroButVolumeHasSpace() async {
        // Reproduces the exFAT bug end-to-end at the plan gate: the canonical reader turns
        // (importantUsage: 0, ordinary: 500 GB) into a positive capacity, so the plan is not blocked.
        let gb: Int64 = 1_073_741_824
        let free = SystemStorage.selectAvailableBytes(importantUsage: 0, ordinaryAvailable: 500 * gb)
        #expect(free == 500 * gb)
        let mgr = LocalModelManager(root: tempRoot(),
                                    deviceProfileProvider: FixedProfile(storage: UInt64(free!), physical: 16 << 30))
        let d = descriptor(url: URL(string: "http://127.0.0.1:1/x")!, bytes: 986_048_768, sha: "00")
        let plan = await mgr.installPlan(for: d)
        #expect(plan.availableStorageBytes == 500 * gb)
        #expect(plan.storageSufficient == true)
        #expect(plan.suitable == true)
    }

    @Test func installFailsFastOnInsufficientStorage() async {
        let mgr = LocalModelManager(root: tempRoot(), deviceProfileProvider: FixedProfile(storage: 1 * 1024 * 1024, physical: 8 << 30))
        let d = descriptor(url: URL(string: "http://127.0.0.1:1/x")!, bytes: 986_048_768, sha: "00")
        await #expect(throws: LocalModelError.self) { _ = try await mgr.install(d) }
    }

    @Test func downloadVerifiesAndInstalls_thenRemoves() async throws {
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        let server = try TestHTTPServer(body: payload); defer { server.stop() }
        let root = tempRoot()
        let mgr = LocalModelManager(root: root, deviceProfileProvider: FixedProfile(storage: 8 << 30, physical: 8 << 30))
        let d = descriptor(url: server.url(), bytes: Int64(payload.count), sha: sha256Hex(payload))

        #expect(await mgr.state(for: d) == .notInstalled)
        let install = try await mgr.install(d)
        #expect(install.spec.backend == .gguf)
        #expect(await mgr.isInstalled(d.id))
        #expect(await mgr.state(for: d) == .installed)
        // File exists on disk at the recorded path
        #expect(FileManager.default.fileExists(atPath: install.installPath))

        // Duplicate install request → typed error
        await #expect(throws: LocalModelError.self) { _ = try await mgr.install(d) }

        // Remove → gone
        try await mgr.remove(d.id)
        #expect(await mgr.isInstalled(d.id) == false)
        #expect(await mgr.state(for: d) == .notInstalled)
        #expect(FileManager.default.fileExists(atPath: install.installPath) == false)
    }

    @Test func checksumMismatchIsRejected() async throws {
        let payload = Data((0..<50_000).map { UInt8($0 % 251) })
        let server = try TestHTTPServer(body: payload); defer { server.stop() }
        let mgr = LocalModelManager(root: tempRoot(), deviceProfileProvider: FixedProfile(storage: 8 << 30, physical: 8 << 30))
        // Correct length, WRONG sha → checksum mismatch, not installed.
        let d = descriptor(url: server.url(), bytes: Int64(payload.count), sha: String(repeating: "a", count: 64))
        await #expect(throws: LocalModelError.self) { _ = try await mgr.install(d) }
        #expect(await mgr.isInstalled(d.id) == false)
    }

    @Test func contentLengthMismatchIsRejected() async throws {
        let payload = Data((0..<50_000).map { UInt8($0 % 251) })
        // Advertise more bytes than we send → size mismatch.
        let server = try TestHTTPServer(body: payload, contentLengthOverride: payload.count + 10_000); defer { server.stop() }
        let mgr = LocalModelManager(root: tempRoot(), deviceProfileProvider: FixedProfile(storage: 8 << 30, physical: 8 << 30))
        let d = descriptor(url: server.url(), bytes: Int64(payload.count) + 10_000, sha: sha256Hex(payload))
        await #expect(throws: Error.self) { _ = try await mgr.install(d) }
        #expect(await mgr.isInstalled(d.id) == false)
    }

    @Test func installRecordWithoutFileIsNotInstalled() async throws {
        let root = tempRoot()
        let store = FileModelStore(root: root)
        let d = LocalModelCatalog.descriptor(id: "qwen2.5-0.5b-instruct-q4km")!
        // Save a record but do NOT create the model file.
        try store.save(manifest: ModelManifest(install: ModelInstall(id: d.id, spec: d.makeSpec(), installPath: "/nope/model.gguf", sizeBytes: d.expectedBytes, backendFormat: "gguf"), files: ["model.gguf"]))
        let mgr = LocalModelManager(root: root, deviceProfileProvider: FixedProfile(storage: 8 << 30, physical: 8 << 30))
        #expect(await mgr.isInstalled(d.id) == false)   // record present but file missing → not installed
    }

    @Test func removeNonInstalledThrows() async {
        let mgr = LocalModelManager(root: tempRoot(), deviceProfileProvider: FixedProfile(storage: 8 << 30, physical: 8 << 30))
        await #expect(throws: LocalModelError.self) { try await mgr.remove("nope") }
    }
}
