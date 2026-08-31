import Foundation

/// Persisted storage configuration for esh.
///
/// This lives on the **internal** state root (`<stateRoot>/storage.json`) so it can always be
/// read even when the configured external assets volume is disconnected. It records where large
/// AI assets (model weights, GGUF files, TTS voices, caches, downloads) should live, separately
/// from lightweight config/state which always stays on the internal disk.
///
/// See docs/STORAGE.md and docs/STABILIZATION_BASELINE.md §2.
public struct StorageConfig: Codable, Sendable, Equatable {
    /// Current storage schema version. Bump when the on-disk layout or this schema changes so
    /// future releases can migrate deterministically.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int

    /// Absolute path to the assets root. `nil` means "use the internal state root" (the
    /// zero-configuration default). Stored as a string (not URL) so `~` and unicode/space paths
    /// round-trip cleanly through JSON.
    public var assetsRoot: String?

    /// Stable identifier of the volume/directory the assets root was bound to. Matched against a
    /// marker file written into the assets root so esh can tell "volume disconnected" apart from
    /// "a different volume is now mounted here" and avoid silently duplicating assets internally.
    public var assetsVolumeID: String?

    public init(
        schemaVersion: Int = StorageConfig.currentSchemaVersion,
        assetsRoot: String? = nil,
        assetsVolumeID: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.assetsRoot = assetsRoot
        self.assetsVolumeID = assetsVolumeID
    }

    public static let `internal` = StorageConfig()

    public var usesExternalAssets: Bool {
        guard let assetsRoot, !assetsRoot.trimmingCharacters(in: .whitespaces).isEmpty else {
            return false
        }
        return true
    }
}

/// Marker file written into an assets root (`<assetsRoot>/.esh-storage.json`). Its presence and
/// matching id prove that the expected volume is actually mounted at the configured path.
public struct StorageMarker: Codable, Sendable, Equatable {
    public var id: String
    public var schemaVersion: Int
    public var label: String?

    public init(
        id: String = UUID().uuidString,
        schemaVersion: Int = StorageConfig.currentSchemaVersion,
        label: String? = nil
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.label = label
    }
}

/// Classification of what a storage location holds, used for reporting and for deciding what a
/// migration should move.
public enum StorageClass: String, Sendable, CaseIterable {
    case models        // MLX/HF model weights and GGUF files
    case caches        // prompt / KV / compression cache artifacts
    case audio         // TTS/voice model weights and generated audio
    case temp          // download staging / temporary files
}

/// Result of checking whether the configured assets root is usable right now.
public enum StorageAvailability: Sendable, Equatable {
    /// Assets live on the internal state root; always available.
    case internalRoot(freeBytes: Int64?)
    /// External assets root is mounted, verified, and writable.
    case available(freeBytes: Int64?)
    /// External assets root is configured but not usable right now.
    case unavailable(reason: String)

    public var isUsable: Bool {
        switch self {
        case .internalRoot, .available:
            return true
        case .unavailable:
            return false
        }
    }

    public var freeBytes: Int64? {
        switch self {
        case let .internalRoot(bytes), let .available(bytes):
            return bytes
        case .unavailable:
            return nil
        }
    }
}

public enum StorageError: Error, LocalizedError, CustomStringConvertible, Equatable {
    case volumeUnavailable(path: String, reason: String)
    case notWritable(path: String)
    case invalidPath(String)
    case migrationFailed(String)

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case let .volumeUnavailable(path, reason):
            return "Model storage volume is unavailable at \(path): \(reason). "
                + "Reconnect the volume (or run `esh storage use-internal`) and try again. "
                + "esh will not re-download large assets onto the internal disk automatically."
        case let .notWritable(path):
            return "Storage path is not writable: \(path)."
        case let .invalidPath(path):
            return "Invalid storage path: \(path)."
        case let .migrationFailed(reason):
            return "Storage migration failed: \(reason)."
        }
    }

    public var localizedDescription: String { description }
}
