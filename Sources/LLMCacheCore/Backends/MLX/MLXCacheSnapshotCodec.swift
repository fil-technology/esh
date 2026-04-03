import Foundation

public struct MLXCacheSnapshotCodec: CacheSnapshotCodec, Sendable {
    public let formatVersion: String

    public init(formatVersion: String = "mlx-cache-snapshot-v1") {
        self.formatVersion = formatVersion
    }

    public func encode(snapshot: CacheSnapshot) throws -> Data {
        try JSONCoding.encoder.encode(snapshot)
    }

    public func decode(data: Data) throws -> CacheSnapshot {
        try JSONCoding.decoder.decode(CacheSnapshot.self, from: data)
    }
}
