import Foundation

public struct CompressionResult: Codable, Hashable, Sendable {
    public var data: Data
    public var compressedSize: Int64
    public var originalSize: Int64

    public init(data: Data, compressedSize: Int64, originalSize: Int64) {
        self.data = data
        self.compressedSize = compressedSize
        self.originalSize = originalSize
    }
}

public protocol CacheCompressor: Sendable {
    var mode: CacheMode { get }
    var version: String { get }

    func compress(_ data: Data) async throws -> CompressionResult
    func decompress(_ data: Data) async throws -> Data
}
