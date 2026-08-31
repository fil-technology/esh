import Foundation

public struct SystemStorageSnapshot: Sendable {
    public let availableBytes: Int64

    public init(availableBytes: Int64) {
        self.availableBytes = availableBytes
    }
}

public enum SystemStorage {
    public static func snapshot(at url: URL) -> SystemStorageSnapshot? {
        guard let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]) else {
            return nil
        }

        // `volumeAvailableCapacityForImportantUsage` is APFS-specific and returns 0 on non-APFS
        // volumes (e.g. an ExFAT external SSD). Only trust it when positive; otherwise fall back to
        // the plain available-capacity key, which is accurate on those volumes.
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            return SystemStorageSnapshot(availableBytes: important)
        }
        if let available = values.volumeAvailableCapacity, available > 0 {
            return SystemStorageSnapshot(availableBytes: Int64(available))
        }
        return nil
    }
}
