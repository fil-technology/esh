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

        if let available = values.volumeAvailableCapacityForImportantUsage {
            return SystemStorageSnapshot(availableBytes: available)
        }
        if let available = values.volumeAvailableCapacity {
            return SystemStorageSnapshot(availableBytes: Int64(available))
        }
        return nil
    }
}
