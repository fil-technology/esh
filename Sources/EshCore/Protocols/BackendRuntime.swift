import Foundation

public struct GenerationConfig: Codable, Hashable, Sendable {
    public var maxTokens: Int
    public var temperature: Double
    public var topP: Double?
    public var topK: Int?
    public var minP: Double?
    public var repetitionPenalty: Double?
    public var seed: UInt64?
    public var enableThinking: Bool?
    public var thinkingBudget: Int?
    public var thinkingStartToken: String?
    public var thinkingEndToken: String?
    public var kvBits: Double?
    public var kvQuantScheme: String?
    public var kvGroupSize: Int?
    public var quantizedKVStart: Int?

    public init(
        maxTokens: Int = 512,
        temperature: Double = 0.7,
        topP: Double? = nil,
        topK: Int? = nil,
        minP: Double? = nil,
        repetitionPenalty: Double? = nil,
        seed: UInt64? = nil,
        enableThinking: Bool? = nil,
        thinkingBudget: Int? = nil,
        thinkingStartToken: String? = nil,
        thinkingEndToken: String? = nil,
        kvBits: Double? = nil,
        kvQuantScheme: String? = nil,
        kvGroupSize: Int? = nil,
        quantizedKVStart: Int? = nil
    ) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.repetitionPenalty = repetitionPenalty
        self.seed = seed
        self.enableThinking = enableThinking
        self.thinkingBudget = thinkingBudget
        self.thinkingStartToken = thinkingStartToken
        self.thinkingEndToken = thinkingEndToken
        self.kvBits = kvBits
        self.kvQuantScheme = kvQuantScheme
        self.kvGroupSize = kvGroupSize
        self.quantizedKVStart = quantizedKVStart
    }

    enum CodingKeys: String, CodingKey {
        case maxTokens
        case temperature
        case topP
        case topK
        case minP
        case repetitionPenalty
        case seed
        case enableThinking
        case thinkingBudget
        case thinkingStartToken
        case thinkingEndToken
        case kvBits
        case kvQuantScheme
        case kvGroupSize
        case quantizedKVStart
    }

    enum SnakeCaseCodingKeys: String, CodingKey {
        case maxTokens = "max_tokens"
        case topP = "top_p"
        case topK = "top_k"
        case minP = "min_p"
        case repetitionPenalty = "repetition_penalty"
        case enableThinking = "enable_thinking"
        case thinkingBudget = "thinking_budget"
        case thinkingStartToken = "thinking_start_token"
        case thinkingEndToken = "thinking_end_token"
        case kvBits = "kv_bits"
        case kvQuantScheme = "kv_quant_scheme"
        case kvGroupSize = "kv_group_size"
        case quantizedKVStart = "quantized_kv_start"
    }

    public init(from decoder: Decoder) throws {
        let defaults = GenerationConfig()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let snakeContainer = try decoder.container(keyedBy: SnakeCaseCodingKeys.self)

        self.maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens)
            ?? snakeContainer.decodeIfPresent(Int.self, forKey: .maxTokens)
            ?? defaults.maxTokens
        self.temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
            ?? defaults.temperature
        self.topP = try container.decodeIfPresent(Double.self, forKey: .topP)
            ?? snakeContainer.decodeIfPresent(Double.self, forKey: .topP)
        self.topK = try container.decodeIfPresent(Int.self, forKey: .topK)
            ?? snakeContainer.decodeIfPresent(Int.self, forKey: .topK)
        self.minP = try container.decodeIfPresent(Double.self, forKey: .minP)
            ?? snakeContainer.decodeIfPresent(Double.self, forKey: .minP)
        self.repetitionPenalty = try container.decodeIfPresent(Double.self, forKey: .repetitionPenalty)
            ?? snakeContainer.decodeIfPresent(Double.self, forKey: .repetitionPenalty)
        self.seed = try container.decodeIfPresent(UInt64.self, forKey: .seed)
        self.enableThinking = try container.decodeIfPresent(Bool.self, forKey: .enableThinking)
            ?? snakeContainer.decodeIfPresent(Bool.self, forKey: .enableThinking)
        self.thinkingBudget = try container.decodeIfPresent(Int.self, forKey: .thinkingBudget)
            ?? snakeContainer.decodeIfPresent(Int.self, forKey: .thinkingBudget)
        self.thinkingStartToken = try container.decodeIfPresent(String.self, forKey: .thinkingStartToken)
            ?? snakeContainer.decodeIfPresent(String.self, forKey: .thinkingStartToken)
        self.thinkingEndToken = try container.decodeIfPresent(String.self, forKey: .thinkingEndToken)
            ?? snakeContainer.decodeIfPresent(String.self, forKey: .thinkingEndToken)
        self.kvBits = try container.decodeIfPresent(Double.self, forKey: .kvBits)
            ?? snakeContainer.decodeIfPresent(Double.self, forKey: .kvBits)
        self.kvQuantScheme = try container.decodeIfPresent(String.self, forKey: .kvQuantScheme)
            ?? snakeContainer.decodeIfPresent(String.self, forKey: .kvQuantScheme)
        self.kvGroupSize = try container.decodeIfPresent(Int.self, forKey: .kvGroupSize)
            ?? snakeContainer.decodeIfPresent(Int.self, forKey: .kvGroupSize)
        self.quantizedKVStart = try container.decodeIfPresent(Int.self, forKey: .quantizedKVStart)
            ?? snakeContainer.decodeIfPresent(Int.self, forKey: .quantizedKVStart)
    }
}

public protocol BackendRuntime: Sendable {
    var backend: BackendKind { get }
    var modelID: String { get }
    var metrics: Metrics { get async }

    func prepare(session: ChatSession) async throws
    func generate(
        session: ChatSession,
        config: GenerationConfig
    ) -> AsyncThrowingStream<String, Error>

    func exportRuntimeCache() async throws -> CacheSnapshot
    func importRuntimeCache(_ snapshot: CacheSnapshot) async throws
    func validateCacheCompatibility(_ manifest: CacheManifest) async throws
    func unload() async
}
