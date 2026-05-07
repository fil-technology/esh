import Foundation

public struct TurboQuantCompressor: CacheCompressor, Sendable {
    public let mode: CacheMode = .turbo
    public let version: String
    private let bridge: TurboQuantBridge

    public init(
        version: String = "mlx-vlm-turboquant-v0.5.0",
        bridge: TurboQuantBridge = .init()
    ) {
        self.version = version
        self.bridge = bridge
    }

    public func compress(_ data: Data) async throws -> CompressionResult {
        let compressed = try bridge.compress(data)
        return CompressionResult(
            data: compressed,
            compressedSize: Int64(compressed.count),
            originalSize: Int64(data.count)
        )
    }

    public func decompress(_ data: Data) async throws -> Data {
        try bridge.decompress(data)
    }
}
