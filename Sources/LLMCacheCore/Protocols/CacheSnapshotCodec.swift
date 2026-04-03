import Foundation

public protocol CacheSnapshotCodec: Sendable {
    var formatVersion: String { get }

    func encode(snapshot: CacheSnapshot) throws -> Data
    func decode(data: Data) throws -> CacheSnapshot
}
