import Foundation

/// Machine-readable snapshot of the storage layout. Shared by `esh storage show` and
/// `esh doctor --json` so Ashex/external tooling has one stable schema.
public struct StorageReport: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var stateRoot: String
    public var assetsRoot: String
    public var external: Bool
    /// "internal" | "available" | "unavailable"
    public var status: String
    public var reason: String?
    public var freeBytes: Int64?
    public var locations: [StorageLocationReport]

    public init(
        schemaVersion: Int,
        stateRoot: String,
        assetsRoot: String,
        external: Bool,
        status: String,
        reason: String?,
        freeBytes: Int64?,
        locations: [StorageLocationReport]
    ) {
        self.schemaVersion = schemaVersion
        self.stateRoot = stateRoot
        self.assetsRoot = assetsRoot
        self.external = external
        self.status = status
        self.reason = reason
        self.freeBytes = freeBytes
        self.locations = locations
    }
}

public struct StorageLocationReport: Codable, Sendable, Equatable {
    public var storageClass: String
    public var path: String
    public var exists: Bool
    public var sizeBytes: Int64?

    public init(storageClass: String, path: String, exists: Bool, sizeBytes: Int64?) {
        self.storageClass = storageClass
        self.path = path
        self.exists = exists
        self.sizeBytes = sizeBytes
    }
}

/// High-level storage operations: availability checks, selecting/relocating the assets root,
/// migrating existing assets, and reporting. This is the single place that enforces the safety
/// rule "never silently duplicate large assets onto the internal disk."
public struct StorageService: Sendable {
    // FileManager is not Sendable; `.default` is process-global and safe for these operations.
    private var fileManager: FileManager { .default }

    public init() {}

    // MARK: - Availability

    public func availability(root: PersistenceRoot) -> StorageAvailability {
        guard root.usesExternalAssets else {
            return .internalRoot(freeBytes: SystemStorage.snapshot(at: root.stateRootURL)?.availableBytes)
        }

        let store = StorageConfigStore(stateRootURL: root.stateRootURL)
        let config = store.load()
        let assetsRoot = root.assetsRootURL

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: assetsRoot.path, isDirectory: &isDir), isDir.boolValue else {
            return .unavailable(reason: "no directory is mounted at this path (the volume may be disconnected)")
        }
        guard let marker = store.readMarker(inAssetsRoot: assetsRoot) else {
            return .unavailable(
                reason: "the esh storage marker is missing (the volume may be disconnected, or a different volume is mounted here)"
            )
        }
        if let expected = config.assetsVolumeID, expected != marker.id {
            return .unavailable(
                reason: "a different storage volume is mounted here (expected \(expected.prefix(8))…, found \(marker.id.prefix(8))…)"
            )
        }
        guard isWritable(assetsRoot) else {
            return .unavailable(reason: "the volume is mounted but not writable")
        }
        return .available(freeBytes: SystemStorage.snapshot(at: assetsRoot)?.availableBytes)
    }

    /// Throw a clear error if the configured assets root is not usable. Call this before any large
    /// download/write (model install, TTS voice download, cache build).
    public func ensureAssetsAvailable(root: PersistenceRoot) throws {
        if case let .unavailable(reason) = availability(root: root) {
            throw StorageError.volumeUnavailable(path: root.assetsRootURL.path, reason: reason)
        }
    }

    // MARK: - Reporting

    public func report(root: PersistenceRoot, computeSizes: Bool = true) -> StorageReport {
        let availability = availability(root: root)
        let status: String
        var reason: String?
        switch availability {
        case .internalRoot: status = "internal"
        case .available: status = "available"
        case let .unavailable(why): status = "unavailable"; reason = why
        }

        let usable = availability.isUsable
        let locations: [StorageLocationReport] = [
            (StorageClass.models, root.modelsURL),
            (StorageClass.caches, root.cachesURL),
            (StorageClass.audio, root.audioURL),
            (StorageClass.temp, root.tempURL)
        ].map { pair in
            let (kind, url) = pair
            let exists = fileManager.fileExists(atPath: url.path)
            let size = (computeSizes && usable && exists) ? directorySize(at: url) : nil
            return StorageLocationReport(
                storageClass: kind.rawValue,
                path: url.path,
                exists: exists,
                sizeBytes: size
            )
        }

        return StorageReport(
            schemaVersion: StorageConfig.currentSchemaVersion,
            stateRoot: root.stateRootURL.path,
            assetsRoot: root.assetsRootURL.path,
            external: root.usesExternalAssets,
            status: status,
            reason: reason,
            freeBytes: availability.freeBytes,
            locations: locations
        )
    }

    // MARK: - Selecting / relocating the assets root

    /// Point large assets at `rawPath`. Validates writability, writes a volume marker, records the
    /// choice in the internal `storage.json`, and (optionally) migrates existing assets. Returns the
    /// new `PersistenceRoot`.
    @discardableResult
    public func setAssetsRoot(
        _ rawPath: String,
        migrateExisting: Bool,
        root: PersistenceRoot,
        progress: (@Sendable (String) -> Void)? = nil
    ) throws -> PersistenceRoot {
        let target = PathResolving.directoryURL(from: rawPath)
        guard !target.path.isEmpty, target.path != "/" else {
            throw StorageError.invalidPath(rawPath)
        }

        do {
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        } catch {
            throw StorageError.volumeUnavailable(
                path: target.path,
                reason: "could not create the directory (is the volume mounted?): \(error.localizedDescription)"
            )
        }
        guard isWritable(target) else {
            throw StorageError.notWritable(path: target.path)
        }

        let store = StorageConfigStore(stateRootURL: root.stateRootURL)
        let marker = try store.writeMarker(inAssetsRoot: target)
        let newRoot = PersistenceRoot(stateRootURL: root.stateRootURL, assetsRootURL: target)

        if migrateExisting, root.assetsRootURL.standardizedFileURL != target.standardizedFileURL {
            try migrateAssets(from: root, to: newRoot, progress: progress)
        }

        var config = store.load()
        config.schemaVersion = StorageConfig.currentSchemaVersion
        config.assetsRoot = target.path
        config.assetsVolumeID = marker.id
        try store.save(config)
        return newRoot
    }

    /// Revert to keeping large assets on the internal state root.
    @discardableResult
    public func useInternal(
        migrateExisting: Bool,
        root: PersistenceRoot,
        progress: (@Sendable (String) -> Void)? = nil
    ) throws -> PersistenceRoot {
        let newRoot = PersistenceRoot(rootURL: root.stateRootURL)
        if migrateExisting, root.usesExternalAssets {
            // Only attempt migration if the external volume is actually available.
            if availability(root: root).isUsable {
                try migrateAssets(from: root, to: newRoot, progress: progress)
            } else {
                throw StorageError.volumeUnavailable(
                    path: root.assetsRootURL.path,
                    reason: "cannot migrate assets to internal storage because the external volume is not available"
                )
            }
        }
        let store = StorageConfigStore(stateRootURL: root.stateRootURL)
        var config = store.load()
        config.schemaVersion = StorageConfig.currentSchemaVersion
        config.assetsRoot = nil
        config.assetsVolumeID = nil
        try store.save(config)
        return newRoot
    }

    // MARK: - Migration

    /// Move models/caches/audio/temp from one assets root to another. Uses move where possible and
    /// falls back to copy+remove across volumes; merges into existing destination directories.
    public func migrateAssets(
        from source: PersistenceRoot,
        to destination: PersistenceRoot,
        progress: (@Sendable (String) -> Void)? = nil
    ) throws {
        let pairs: [(StorageClass, URL, URL)] = [
            (.models, source.modelsURL, destination.modelsURL),
            (.caches, source.cachesURL, destination.cachesURL),
            (.audio, source.audioURL, destination.audioURL),
            (.temp, source.tempURL, destination.tempURL)
        ]
        for (kind, from, to) in pairs {
            guard fileManager.fileExists(atPath: from.path) else { continue }
            if from.standardizedFileURL == to.standardizedFileURL { continue }
            progress?("Migrating \(kind.rawValue)…")
            try moveOrMerge(from: from, to: to)
        }
    }

    private func moveOrMerge(from: URL, to: URL) throws {
        if !fileManager.fileExists(atPath: to.path) {
            try fileManager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try fileManager.moveItem(at: from, to: to)
                return
            } catch {
                try fileManager.copyItem(at: from, to: to)
                try? fileManager.removeItem(at: from)
                return
            }
        }
        // Destination exists — merge children.
        guard let items = try? fileManager.contentsOfDirectory(at: from, includingPropertiesForKeys: nil) else {
            return
        }
        for item in items {
            let dest = to.appendingPathComponent(item.lastPathComponent)
            if fileManager.fileExists(atPath: dest.path) { continue }
            do {
                try fileManager.moveItem(at: item, to: dest)
            } catch {
                try fileManager.copyItem(at: item, to: dest)
                try? fileManager.removeItem(at: item)
            }
        }
    }

    // MARK: - Helpers

    private func isWritable(_ directory: URL) -> Bool {
        let probe = directory.appendingPathComponent(".esh-write-probe-\(UUID().uuidString)")
        do {
            try Data("ok".utf8).write(to: probe, options: .atomic)
            try? fileManager.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    public func directorySize(at url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey],
            options: [],
            errorHandler: nil
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }
}
