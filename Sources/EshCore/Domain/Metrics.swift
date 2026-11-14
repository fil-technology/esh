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
    /// Memory the runtime keeps resident BETWEEN requests beyond its weights (e.g. a persistent worker's
    /// session KV/prefix caches). The warm pool budgets it and can release it under pressure.
    public var residentCacheBytes: Int64?
    /// Prompt prefill throughput (tokens/s) as measured by the backend.
    public var promptTokensPerSecond: Double?
    /// Speculative decoding (when enabled): tokens proposed and tokens accepted by verification.
    public var draftTokens: Int?
    public var draftAcceptedTokens: Int?
    /// Set when the runtime silently degraded a requested capability (e.g. the automatic KV mode fell back from
    /// TurboQuant to a raw cache because its Python dependency is missing) — never nil-and-quiet anymore.
    public var kvModeFallback: String?
    /// Effective prompt-prefix cache mode for this request ("live", "tokens" or "legacy") and, when live caching
    /// could not hold the session, why it fell back to the token-exact snapshot.
    public var prefixCacheMode: String?
    public var prefixCacheFallback: String?

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
        cachedTokens: Int? = nil,
        residentCacheBytes: Int64? = nil,
        promptTokensPerSecond: Double? = nil,
        draftTokens: Int? = nil,
        draftAcceptedTokens: Int? = nil
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
        self.residentCacheBytes = residentCacheBytes
        self.promptTokensPerSecond = promptTokensPerSecond
        self.draftTokens = draftTokens
        self.draftAcceptedTokens = draftAcceptedTokens
    }
}
