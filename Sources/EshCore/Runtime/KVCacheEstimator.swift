import Foundation

/// Estimates how much KV-cache memory a request will add, from the model's own `config.json` — the input to the
/// warm pool's context-growth guard (`RuntimeLifecycleManager.ensureHeadroom`). Deliberately conservative: it counts
/// the whole prompt (even if a prefix will be reused from cache) plus every allowed new token, at 2 bytes/element.
public enum KVCacheEstimator {
    /// Bytes of K+V per token for a transformer config (layers x kv heads x head dim x 2 tensors x 2 bytes).
    /// Handles multimodal configs that nest the language model under `text_config`. nil when unknown.
    public static func bytesPerToken(config: [String: Any]) -> Int64? {
        let c = (config["text_config"] as? [String: Any]).map { $0.merging(config) { inner, _ in inner } } ?? config
        func int(_ k: String) -> Int? { (c[k] as? NSNumber)?.intValue }
        guard let layers = int("num_hidden_layers") ?? int("n_layer") ?? int("num_layers"), layers > 0,
              let heads = int("num_attention_heads") ?? int("n_head"), heads > 0 else { return nil }
        let kvHeads = int("num_key_value_heads") ?? heads
        let headDim = int("head_dim") ?? int("hidden_size").map { $0 / heads }
        guard let headDim, headDim > 0, kvHeads > 0 else { return nil }
        return Int64(layers) * Int64(kvHeads) * Int64(headDim) * 2 * 2
    }

    public static func bytesPerToken(modelDirectory: URL) -> Int64? {
        let url = modelDirectory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return bytesPerToken(config: obj)
    }

    /// Conservative token estimate for text the client sent (≈3 characters per token, plus template overhead).
    public static func estimatedTokens(characters: Int, messages: Int = 1) -> Int {
        characters / 3 + 16 * max(1, messages) + 64
    }

    /// Additional KV bytes a request may add: (prompt tokens + max new tokens) x bytes per token.
    public static func growthBytes(bytesPerToken: Int64, promptCharacters: Int, messages: Int, maxTokens: Int) -> Int64 {
        Int64(estimatedTokens(characters: promptCharacters, messages: messages) + max(0, maxTokens)) * bytesPerToken
    }
}
