import Foundation

public struct SystemStorageSnapshot: Sendable {
    public let availableBytes: Int64

    public init(availableBytes: Int64) {
        self.availableBytes = availableBytes
    }
}

/// The single, canonical cross-filesystem free-capacity reader. Every storage gate (Model Fit, install
/// preflight, StorageService, DeviceProfile) must go through here so behavior is identical on APFS and
/// non-APFS (exFAT/FAT) volumes.
public enum SystemStorage {
    /// Pure capacity selection — testable without mounting a real volume.
    ///
    /// `volumeAvailableCapacityForImportantUsage` ("can I download this?") is APFS-specific and reports **0**
    /// on non-APFS volumes such as an exFAT external SSD, so it is trusted only when strictly positive.
    /// Otherwise the plain `volumeAvailableCapacity` reading is used **verbatim** — including a genuine `0`
    /// on a full volume (a real measurement, never collapsed to "unknown"). Returns `nil` only when neither
    /// capacity signal could be read.
    ///
    /// - Case A (importantUsage > 0, ordinary > 0) → importantUsage (preferred meaningful signal).
    /// - Case B (importantUsage == 0, ordinary > 0) → ordinary (the exFAT production bug).
    /// - Case C (importantUsage == nil, ordinary > 0) → ordinary.
    /// - Case D (importantUsage == 0, ordinary == 0) → 0 (genuinely full, preserved).
    /// - Neither readable → nil (genuinely unknown).
    public static func selectAvailableBytes(importantUsage: Int64?, ordinaryAvailable: Int64?) -> Int64? {
        if let important = importantUsage, important > 0 {
            return important
        }
        if let ordinary = ordinaryAvailable {
            return max(0, ordinary)   // a successful read is real, including 0 on a full volume
        }
        return nil
    }

    public static func snapshot(at url: URL) -> SystemStorageSnapshot? {
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]) else {
            return nil
        }
        let important = values.volumeAvailableCapacityForImportantUsage            // Int64?
        let ordinary = values.volumeAvailableCapacity.map(Int64.init)              // Int? → Int64?
        guard let bytes = selectAvailableBytes(importantUsage: important, ordinaryAvailable: ordinary) else {
            return nil
        }
        return SystemStorageSnapshot(availableBytes: bytes)
    }
}
