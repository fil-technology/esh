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

        if let available = availableCapacity(
            importantUsage: values.volumeAvailableCapacityForImportantUsage,
            generalAvailable: values.volumeAvailableCapacity.map(Int64.init)
        ) {
            return SystemStorageSnapshot(availableBytes: available)
        }
        return nil
    }

    static func availableCapacity(importantUsage: Int64?, generalAvailable: Int64?) -> Int64? {
        if let importantUsage, importantUsage > 0 {
            return importantUsage
        }
        if let generalAvailable, generalAvailable > 0 {
            return generalAvailable
        }
        return importantUsage ?? generalAvailable
    }
}
