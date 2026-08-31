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
    /// Realized prompt/KV cache state for THIS request (what actually happened, not the chosen
    /// strategy): whether a cached prefix was reused, and how many tokens it saved reprocessing.
    public var cacheHit: Bool?
    public var cachedTokens: Int?

    public init(
        contextTokens: Int? = nil,
        ttftMilliseconds: Double? = nil,
        tokensPerSecond: Double? = nil,
        memoryBytes: Int64? = nil,
        cacheSizeBytes: Int64? = nil,
        compressionRatio: Double? = nil,
        promptTokens: Int? = nil,
        generationTokens: Int? = nil,
        finishReason: String? = nil,
        cacheHit: Bool? = nil,
        cachedTokens: Int? = nil
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
        self.cacheHit = cacheHit
        self.cachedTokens = cachedTokens
    }
}
