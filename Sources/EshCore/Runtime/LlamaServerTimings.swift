import Foundation

/// The `timings` object llama-server attaches to the final streamed chunk of a completion. esh previously
/// recorded only a client-side TTFT for GGUF; this carries the server's own prefill/decode measurements and
/// speculative-decoding acceptance into `Metrics`.
public struct LlamaServerTimings: Equatable, Sendable {
    public var promptTokens: Int?
    public var cachedTokens: Int?
    public var promptMilliseconds: Double?
    public var promptTokensPerSecond: Double?
    public var generatedTokens: Int?
    public var generationTokensPerSecond: Double?
    public var draftTokens: Int?
    public var draftAcceptedTokens: Int?

    /// Parse from a decoded SSE chunk (`{"choices": …, "timings": {…}}`); nil when the chunk has no timings.
    public init?(chunk: [String: Any]) {
        guard let t = chunk["timings"] as? [String: Any] else { return nil }
        func int(_ k: String) -> Int? { (t[k] as? NSNumber)?.intValue }
        func dbl(_ k: String) -> Double? { (t[k] as? NSNumber)?.doubleValue }
        promptTokens = int("prompt_n")
        cachedTokens = int("cache_n")
        promptMilliseconds = dbl("prompt_ms")
        promptTokensPerSecond = dbl("prompt_per_second")
        generatedTokens = int("predicted_n")
        generationTokensPerSecond = dbl("predicted_per_second")
        draftTokens = int("draft_n")
        draftAcceptedTokens = int("draft_n_accepted")
    }

    public init?(chunkData: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: chunkData)) as? [String: Any] else { return nil }
        self.init(chunk: obj)
    }

    /// Merge into the runtime's metrics; the client-side TTFT stays authoritative (it includes queueing).
    public func applied(to base: Metrics) -> Metrics {
        var m = base
        m.promptTokens = promptTokens ?? m.promptTokens
        m.cachedTokens = cachedTokens ?? m.cachedTokens
        m.cacheHit = cachedTokens.map { $0 > 0 } ?? m.cacheHit
        m.promptTokensPerSecond = promptTokensPerSecond ?? m.promptTokensPerSecond
        m.generationTokens = generatedTokens ?? m.generationTokens
        m.tokensPerSecond = generationTokensPerSecond ?? m.tokensPerSecond
        m.draftTokens = draftTokens ?? m.draftTokens
        m.draftAcceptedTokens = draftAcceptedTokens ?? m.draftAcceptedTokens
        return m
    }
}
