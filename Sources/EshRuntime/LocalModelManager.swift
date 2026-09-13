import Foundation
import CryptoKit
import EshCore

// esh M8 — the local model manager. Actor-serialized install lifecycle over existing esh abstractions.
// Portable (EshCore only, no llama.cpp). Execution is done by the app-injected LlamaCppEmbeddedBackend;
// this type only downloads, verifies, records, fits, and removes.

public actor LocalModelManager {
    private let store: ModelStore
    private let root: PersistenceRoot
    private let deviceProfileProvider: DeviceProfileProviding
    /// Free-space margin to keep beyond the model file (app, OS, runtime buffers).
    private let storageSafetyReserveBytes: Int64
    /// Model ids with an install currently running. `install()` releases the actor at its first `await`, so
    /// this guards against two concurrent installs of the same model both starting a download (M10 #9).
    private var installsInFlight: Set<String> = []

    public init(root: PersistenceRoot = .default(),
                store: ModelStore? = nil,
                deviceProfileProvider: DeviceProfileProviding = SystemDeviceProfileProvider(),
                storageSafetyReserveBytes: Int64 = 512 * 1024 * 1024) {
        self.root = root
        self.store = store ?? FileModelStore(root: root)
        self.deviceProfileProvider = deviceProfileProvider
        self.storageSafetyReserveBytes = storageSafetyReserveBytes
    }

    // MARK: Paths (deterministic, sandbox-appropriate; reuses FileModelStore's install dir layout)

    private func installDir(_ id: String) throws -> URL { try store.prepareInstallDirectory(id: id) }
    private func modelFileURL(_ id: String) -> URL {
        installsRoot.appendingPathComponent(id, isDirectory: true).appendingPathComponent("model.gguf")
    }
    private func resumeDataURL(_ id: String) -> URL {
        installsRoot.appendingPathComponent(id, isDirectory: true).appendingPathComponent("model.resume")
    }
    private var installsRoot: URL { root.modelsURL.appendingPathComponent("installs", isDirectory: true) }

    // MARK: Query

    /// A model is installed only when its install record exists AND the model file is present.
    public func isInstalled(_ id: String) -> Bool {
        guard let installs = try? store.listInstalls(), installs.contains(where: { $0.id == id }) else { return false }
        return FileManager.default.fileExists(atPath: modelFileURL(id).path)
    }

    public func state(for d: LocalModelDescriptor) -> LocalModelState {
        if isInstalled(d.id) { return .installed }
        if FileManager.default.fileExists(atPath: resumeDataURL(d.id).path) {
            return .paused(bytesDownloaded: 0)   // resume data present (URLSession resume token; byte count opaque)
        }
        return .notInstalled
    }

    public func statuses() -> [LocalModelStatus] {
        LocalModelCatalog.models.map { LocalModelStatus(descriptor: $0, state: state(for: $0)) }
    }

    // MARK: Preflight (storage + Model Fit, both honest)

    public func installPlan(for d: LocalModelDescriptor) -> LocalModelInstallPlan {
        let profile = deviceProfileProvider.currentProfile()
        let free = profile.availableStorageBytes.map { Int64($0) }
        let need = d.expectedBytes + storageSafetyReserveBytes
        let storageSufficient = free.map { $0 >= need } ?? true   // unknown → don't hard-block, warn
        // Reuse the existing Model Fit over the platform-neutral DeviceProfile.
        let host = HostMachineProfile(deviceProfile: profile)
        let input = ModelFitService.Input(parameterCountB: d.parameterCountB, effectiveBits: 4.5,
                                          format: .gguf, backend: .gguf,
                                          contextTokens: d.recommendedContext,
                                          diskRequiredBytes: d.expectedBytes)
        let fit = ModelFitService().assess(input: input, host: host, root: root).fitClass
        var reasons: [String] = []
        if !storageSufficient {
            reasons.append("Not enough free storage: need ~\(need / 1_048_576) MB (model + reserve), free \(free.map { "\($0 / 1_048_576) MB" } ?? "unknown").")
        }
        if free == nil { reasons.append("Free storage is unknown on this platform; proceeding is at the caller's discretion.") }
        switch fit {
        case .unsupported: reasons.append("Model Fit: unsupported on this device.")
        case .unlikely: reasons.append("Model Fit: unlikely to run comfortably — memory is tight.")
        case .tight: reasons.append("Model Fit: tight — runnable but close to the safe memory budget.")
        case .unknown: reasons.append("Model Fit: unknown — insufficient metadata to judge memory.")
        case .fits, .comfortable: break
        }
        // suitable = storage ok AND not a hard technical block. tight/unlikely are allowed (warned), per spec.
        let suitable = storageSufficient && fit != .unsupported
        return LocalModelInstallPlan(descriptor: d, downloadBytes: d.expectedBytes, availableStorageBytes: free,
                                     storageSafetyReserveBytes: storageSafetyReserveBytes,
                                     storageSufficient: storageSufficient, fit: fit, suitable: suitable, reasons: reasons)
    }

    // MARK: Install (download → verify → record); resumable; cancellation-safe

    @discardableResult
    public func install(_ d: LocalModelDescriptor, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> ModelInstall {
        if isInstalled(d.id) { throw LocalModelError.alreadyInstalled(d.id) }
        // Concurrency guard: only one install per model id at a time. The check+insert is synchronous actor
        // code (atomic); the release runs on every exit path (return / throw / cancellation).
        guard !installsInFlight.contains(d.id) else { throw LocalModelError.installInProgress(d.id) }
        installsInFlight.insert(d.id)
        defer { installsInFlight.remove(d.id) }
        // Storage preflight (hard fail early).
        let plan = installPlan(for: d)
        if !plan.storageSufficient, let free = plan.availableStorageBytes {
            throw LocalModelError.insufficientStorage(needBytes: d.expectedBytes + storageSafetyReserveBytes, freeBytes: free)
        }
        _ = try installDir(d.id)   // ensure dir exists
        let fm = FileManager.default
        let resumeURL = resumeDataURL(d.id)
        let resumeData = try? Data(contentsOf: resumeURL)

        do {
            let downloader = ResumableDownloader(resumeDataURL: resumeURL)
            let outcome = try await downloader.run(request: URLRequest(url: d.sourceURL), resumeData: resumeData,
                                                   onProgress: { p in onProgress?(p) })
            if !(200...299).contains(outcome.httpStatus) {
                try? fm.removeItem(at: outcome.tempURL)
                throw LocalModelError.downloadFailed("HTTP \(outcome.httpStatus)")
            }
            // Verify byte size
            let finalSize = ResumeSupport.existingSize(at: outcome.tempURL)
            guard finalSize == d.expectedBytes else {
                try? fm.removeItem(at: outcome.tempURL)
                throw LocalModelError.contentLengthMismatch(expected: d.expectedBytes, got: finalSize)
            }
            // Verify SHA-256 before it can become an install
            onProgress?(1.0)
            let digest = try Self.sha256Hex(of: outcome.tempURL)
            guard digest == d.sha256 else {
                try? fm.removeItem(at: outcome.tempURL)   // corrupt → discard
                throw LocalModelError.checksumMismatch(expected: d.sha256, got: digest)
            }
            // Atomic finalize into the install dir
            let finalURL = modelFileURL(d.id)
            if fm.fileExists(atPath: finalURL.path) { try? fm.removeItem(at: finalURL) }
            do { try fm.moveItem(at: outcome.tempURL, to: finalURL) }
            catch { try fm.copyItem(at: outcome.tempURL, to: finalURL); try? fm.removeItem(at: outcome.tempURL) }
            try? fm.removeItem(at: resumeURL)   // fully installed → no resume state

            let install = ModelInstall(id: d.id, spec: d.makeSpec(localPath: finalURL.path),
                                       installPath: finalURL.path, sizeBytes: d.expectedBytes,
                                       backendFormat: "gguf", runtimeVersion: "llama.cpp-embedded")
            try store.save(manifest: ModelManifest(install: install, files: ["model.gguf"]))
            return install
        } catch is CancellationError {
            throw CancellationError()   // resume data persisted by the downloader; not installed
        } catch let e as LocalModelError {
            throw e
        } catch {
            throw LocalModelError.downloadFailed(error.localizedDescription)
        }
    }

    // MARK: Reconcile / repair (M10 durability)

    /// Outcome of a store reconciliation — the concrete repairs applied to reach a consistent state.
    public struct ReconcileReport: Sendable, Equatable {
        /// Orphan model files (interrupted finalize: file present, record missing) that verified by
        /// size + SHA-256 and were re-recorded as installed.
        public var recoveredRecords: [String] = []
        /// Records whose model file was missing → removed (a lone record is never usable).
        public var removedBrokenRecords: [String] = []
        /// Install directories with unusable/unverifiable contents (and no valid resume) → removed.
        public var removedOrphanDirs: [String] = []
        /// Leftover resume tokens for models that are fully installed → removed.
        public var clearedStaleResume: [String] = []
        public var isConsistent: Bool {
            recoveredRecords.isEmpty && removedBrokenRecords.isEmpty
                && removedOrphanDirs.isEmpty && clearedStaleResume.isEmpty
        }
    }

    /// Bring the on-disk model store to a consistent state after an interrupted lifecycle (app killed mid
    /// download/verify/finalize/remove). Safe to call at launch. It never reports a half-installed model as
    /// usable: an orphan file is re-recorded ONLY if it verifies (size + SHA-256) against the curated
    /// descriptor; otherwise the record or directory is removed. A legitimate paused download (resume token,
    /// no model file) is preserved.
    @discardableResult
    public func reconcile() -> ReconcileReport { reconcile(catalog: LocalModelCatalog.models) }

    /// Testable core of `reconcile()` — the curated catalog used to verify/recover orphan files is injected.
    @discardableResult
    func reconcile(catalog: [LocalModelDescriptor]) -> ReconcileReport {
        let fm = FileManager.default
        var report = ReconcileReport()
        let installs = (try? store.listInstalls()) ?? []
        let recordIDs = Set(installs.map { $0.id })

        // 1. Records whose model file is missing → not usable → drop the record + dir.
        for install in installs where !fm.fileExists(atPath: modelFileURL(install.id).path) {
            try? store.removeInstall(id: install.id)
            try? fm.removeItem(at: installsRoot.appendingPathComponent(install.id, isDirectory: true))
            report.removedBrokenRecords.append(install.id)
        }

        // 2. Installed records with leftover resume tokens → clear the stale token.
        for install in installs where fm.fileExists(atPath: modelFileURL(install.id).path) {
            let resume = resumeDataURL(install.id)
            if fm.fileExists(atPath: resume.path) {
                try? fm.removeItem(at: resume)
                report.clearedStaleResume.append(install.id)
            }
        }

        // 3. Orphan install directories (no record). Recover a verified model file; otherwise remove a dir
        //    that has neither a valid model nor a resume token.
        let dirs = (try? fm.contentsOfDirectory(at: installsRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for dir in dirs {
            let id = dir.lastPathComponent
            guard !recordIDs.contains(id) else { continue }
            let modelPath = modelFileURL(id).path
            let hasModel = fm.fileExists(atPath: modelPath)
            let hasResume = fm.fileExists(atPath: resumeDataURL(id).path)
            if hasModel, let desc = catalog.first(where: { $0.id == id }),
               ResumeSupport.existingSize(at: modelFileURL(id)) == desc.expectedBytes,
               let digest = try? Self.sha256Hex(of: modelFileURL(id)), digest == desc.sha256 {
                // Interrupted finalize: the file is complete and verified → re-record it as installed.
                let install = ModelInstall(id: id, spec: desc.makeSpec(localPath: modelPath),
                                           installPath: modelPath, sizeBytes: desc.expectedBytes,
                                           backendFormat: "gguf", runtimeVersion: "llama.cpp-embedded")
                if (try? store.save(manifest: ModelManifest(install: install, files: ["model.gguf"]))) != nil {
                    try? fm.removeItem(at: resumeDataURL(id))
                    report.recoveredRecords.append(id)
                    continue
                }
            }
            if hasModel && !hasResume {
                // A model file that cannot be verified (unknown id, wrong size/hash) and no resume → remove.
                try? fm.removeItem(at: dir)
                report.removedOrphanDirs.append(id)
            }
            // else: only a resume token (or empty) → a legitimate paused download; leave it.
        }
        return report
    }

    // MARK: Remove (delete all model-owned files + the install record)

    public func remove(_ id: String) throws {
        let installs = (try? store.listInstalls()) ?? []
        let hasRecord = installs.contains { $0.id == id }
        let dir = installsRoot.appendingPathComponent(id, isDirectory: true)
        let hadFiles = FileManager.default.fileExists(atPath: dir.path)
        if !hasRecord && !hadFiles { throw LocalModelError.notInstalled(id) }
        try? store.removeInstall(id: id)                 // manifest + install dir
        try? FileManager.default.removeItem(at: dir)     // ensure model file + partial gone
    }

    // MARK: helpers

    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
