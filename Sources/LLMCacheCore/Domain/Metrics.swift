import Foundation

public struct Metrics: Codable, Hashable, Sendable {
    public var contextTokens: Int?
    public var ttftMilliseconds: Double?
    public var tokensPerSecond: Double?
    public var memoryBytes: Int64?
    public var cacheSizeBytes: Int64?
    public var compressionRatio: Double?

    public init(
        contextTokens: Int? = nil,
        ttftMilliseconds: Double? = nil,
        tokensPerSecond: Double? = nil,
        memoryBytes: Int64? = nil,
        cacheSizeBytes: Int64? = nil,
        compressionRatio: Double? = nil
    ) {
        self.contextTokens = contextTokens
        self.ttftMilliseconds = ttftMilliseconds
        self.tokensPerSecond = tokensPerSecond
        self.memoryBytes = memoryBytes
        self.cacheSizeBytes = cacheSizeBytes
        self.compressionRatio = compressionRatio
    }
}
