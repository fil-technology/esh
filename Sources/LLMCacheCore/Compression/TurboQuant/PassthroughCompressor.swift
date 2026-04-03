import Foundation

public struct PassthroughCompressor: CacheCompressor, Sendable {
    public let mode: CacheMode = .raw
    public let version: String = "raw-v1"

    public init() {}

    public func compress(_ data: Data) async throws -> CompressionResult {
        CompressionResult(data: data, compressedSize: Int64(data.count), originalSize: Int64(data.count))
    }

    public func decompress(_ data: Data) async throws -> Data {
        data
    }
}
