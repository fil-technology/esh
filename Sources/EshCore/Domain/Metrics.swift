import Foundation

public struct Metrics: Codable, Hashable, Sendable {
    public var contextTokens: Int?
    public var ttftMilliseconds: Double?
    public var tokensPerSecond: Double?
    public var memoryBytes: Int64?
    public var cacheSizeBytes: Int64?
    public var compressionRatio: Double?
    /// Measured token counts reported by the runtime (nil when the backend does not report them).
    public var promptTokens: Int?
    public var generationTokens: Int?
    /// Why generation stopped, as reported by the runtime (e.g. "stop", "length").
    public var finishReason: String?

    public init(
        contextTokens: Int? = nil,
        ttftMilliseconds: Double? = nil,
        tokensPerSecond: Double? = nil,
        memoryBytes: Int64? = nil,
        cacheSizeBytes: Int64? = nil,
        compressionRatio: Double? = nil,
        promptTokens: Int? = nil,
        generationTokens: Int? = nil,
        finishReason: String? = nil
    ) {
        self.contextTokens = contextTokens
        self.ttftMilliseconds = ttftMilliseconds
        self.tokensPerSecond = tokensPerSecond
        self.memoryBytes = memoryBytes
        self.cacheSizeBytes = cacheSizeBytes
        self.compressionRatio = compressionRatio
        self.promptTokens = promptTokens
        self.generationTokens = generationTokens
        self.finishReason = finishReason
    }
}
