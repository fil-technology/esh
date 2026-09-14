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
    /// The single, background-capable download layer (RC follow-up). Owns the URLSession; the verify →
    /// atomic-install pipeline stays here in the manager.
    private let coordinator: ModelDownloadCoordinator

    public init(root: PersistenceRoot = .default(),
                store: ModelStore? = nil,
                deviceProfileProvider: DeviceProfileProviding = SystemDeviceProfileProvider(),
                storageSafetyReserveBytes: Int64 = 512 * 1024 * 1024,
                downloadConfiguration: (@Sendable () -> URLSessionConfiguration)? = nil) {
        self.root = root
        self.store = store ?? FileModelStore(root: root)
        self.deviceProfileProvider = deviceProfileProvider
        self.storageSafetyReserveBytes = storageSafetyReserveBytes
        let installsRoot = root.modelsURL.appendingPathComponent("installs", isDirectory: true)
        self.coordinator = ModelDownloadCoordinator(installsRoot: installsRoot,
                                                    makeConfiguration: downloadConfiguration ?? Self.defaultDownloadConfiguration)
    }

    /// Production download session: a true background `URLSession` on iOS (OS-managed, continues while the
    /// app is suspended, relaunches the app to deliver completion); a foreground/ephemeral session elsewhere
    /// (macOS CLI, tests) where the OS-relaunch semantics do not apply.
    static let defaultDownloadConfiguration: @Sendable () -> URLSessionConfiguration = {
        #if os(iOS)
        let c = URLSessionConfiguration.background(withIdentifier: ModelDownloadCoordinator.backgroundIdentifier)
        c.sessionSendsLaunchEvents = true
        c.isDiscretionary = false
        c.allowsCellularAccess = true
        c.waitsForConnectivity = true
        return c
        #else
        return URLSessionConfiguration.ephemeral
        #endif
    }

    /// Forward the iOS `application(_:handleEventsForBackgroundURLSession:completionHandler:)` event so the
    /// coordinator can finish delivering background-transfer completions, then call the OS handler.
    public func handleBackgroundSessionEvents(identifier: String, completionHandler: @escaping @Sendable () -> Void) {
        guard identifier == ModelDownloadCoordinator.backgroundIdentifier else { completionHandler(); return }
        coordinator.setBackgroundCompletion(completionHandler)
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
        // A persisted download record survives relaunch, so the state stays coherent across backgrounding.
        if let r = coordinator.loadRecord(d.id) {
            switch r.phase {
            case .downloading: return .downloading(progress: r.lastProgress)   // progress may reset to 0 after relaunch
            case .downloaded:  return .verifying                                // transfer done, pending verification
            case .failed:      return .failed(reason: r.reason ?? "download failed")
            }
        }
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
        // Security (M10): reject a descriptor that could escape the sandbox or download over plaintext,
        // before any path is built or any byte is fetched.
        guard LocalModelDescriptor.isValidID(d.id) else { throw LocalModelError.invalidModelID(d.id) }
        guard LocalModelDescriptor.isSecureSource(d.sourceURL) else { throw LocalModelError.insecureSource(d.sourceURL.absoluteString) }
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

        // OS-managed transfer (background on iOS): starts/resumes the download and suspends until this
        // process observes a terminal event. If the app is suspended, iOS keeps transferring; if the process
        // is terminated, the persisted record + staged file let a later runtime finalize via reconcile().
        // Cancelling the surrounding Task cancels the transfer (resume data persisted).
        let terminal = await withTaskCancellationHandler {
            await coordinator.download(modelID: d.id, url: d.sourceURL, expectedBytes: d.expectedBytes,
                                       sha256: d.sha256, onProgress: { p in onProgress?(p) })
        } onCancel: {
            coordinator.cancel(modelID: d.id)
        }

        switch terminal {
        case .cancelled:
            throw CancellationError()                                   // resume data persisted; not installed
        case let .failed(reason):
            throw LocalModelError.downloadFailed(reason)
        case let .staged(url):
            onProgress?(1.0)
            return try finalizeStagedDownload(id: d.id, staged: url, spec: d.makeSpec(localPath: modelFileURL(d.id).path),
                                              expectedBytes: d.expectedBytes, sha256: d.sha256)
        }
    }

    /// Verify (size + SHA-256) a staged download, then atomically finalize it as an install. Shared by the
    /// in-process `install()` path and by `reconcile()` (a transfer that completed while the app was
    /// suspended). Never leaves a corrupt/unverified file resolving as installed: a mismatch discards the
    /// staged file and record and throws a typed error.
    @discardableResult
    private func finalizeStagedDownload(id: String, staged: URL, spec: ModelSpec,
                                        expectedBytes: Int64, sha256: String) throws -> ModelInstall {
        let fm = FileManager.default
        let size = ResumeSupport.existingSize(at: staged)
        guard size == expectedBytes else {
            try? fm.removeItem(at: staged); coordinator.clearRecord(id); try? fm.removeItem(at: resumeDataURL(id))
            throw LocalModelError.contentLengthMismatch(expected: expectedBytes, got: size)
        }
        let digest = try Self.sha256Hex(of: staged)
        guard digest == sha256 else {
            try? fm.removeItem(at: staged); coordinator.clearRecord(id); try? fm.removeItem(at: resumeDataURL(id))
            throw LocalModelError.checksumMismatch(expected: sha256, got: digest)
        }
        let finalURL = modelFileURL(id)
        if fm.fileExists(atPath: finalURL.path) { try? fm.removeItem(at: finalURL) }
        do { try fm.moveItem(at: staged, to: finalURL) }
        catch { try fm.copyItem(at: staged, to: finalURL); try? fm.removeItem(at: staged) }
        try? fm.removeItem(at: resumeDataURL(id))   // fully installed → no resume/staging/record state
        coordinator.clearRecord(id)
        let install = ModelInstall(id: id, spec: spec, installPath: finalURL.path, sizeBytes: expectedBytes,
                                   backendFormat: "gguf", runtimeVersion: "llama.cpp-embedded")
        try store.save(manifest: ModelManifest(install: install, files: ["model.gguf"]))
        return install
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
        /// Background downloads that completed while the app was suspended → verified + installed on relaunch.
        public var finalizedPendingDownloads: [String] = []
        public var isConsistent: Bool {
            recoveredRecords.isEmpty && removedBrokenRecords.isEmpty
                && removedOrphanDirs.isEmpty && clearedStaleResume.isEmpty
                && finalizedPendingDownloads.isEmpty
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
        // Recreate the (background) download session so iOS re-delivers events for outstanding transfers.
        coordinator.reconnect()

        // Background transfers that completed while the app was suspended: a persisted record in the
        // `downloaded` phase with a staged file → verify + atomically install now. Verification failure
        // discards the corrupt file/record (never installs). This is the completion-while-suspended path.
        let dirsForPending = (try? fm.contentsOfDirectory(at: installsRoot, includingPropertiesForKeys: nil)) ?? []
        for d in dirsForPending {
            let id = d.lastPathComponent
            guard let rec = coordinator.loadRecord(id), rec.phase == .downloaded,
                  let stagedPath = rec.stagedPath, fm.fileExists(atPath: stagedPath),
                  !fm.fileExists(atPath: modelFileURL(id).path) else { continue }
            let staged = URL(fileURLWithPath: stagedPath)
            let spec = catalog.first(where: { $0.id == id })?.makeSpec(localPath: modelFileURL(id).path)
                ?? ModelSpec(id: id, displayName: id, backend: .gguf, source: ModelSource(kind: .huggingFace, reference: id))
            if (try? finalizeStagedDownload(id: id, staged: staged, spec: spec,
                                            expectedBytes: rec.expectedBytes, sha256: rec.sha256)) != nil {
                report.finalizedPendingDownloads.append(id)
            }
        }

        // Compute the record set AFTER finalizing pending downloads so later passes see them as installed.
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
            // A live download record (in-flight, or a failed one kept for retry) is not an orphan — leave it.
            if coordinator.loadRecord(id) != nil { continue }
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
        // Security (M10): never let an unsafe id drive a filesystem delete outside the installs root.
        guard LocalModelDescriptor.isValidID(id) else { throw LocalModelError.invalidModelID(id) }
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
