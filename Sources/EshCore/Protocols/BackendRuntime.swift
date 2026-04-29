import Foundation

public struct GenerationConfig: Codable, Hashable, Sendable {
    public var maxTokens: Int
    public var temperature: Double
    public var topP: Double?
    public var topK: Int?
    public var minP: Double?
    public var repetitionPenalty: Double?
    public var seed: UInt64?

    public init(
        maxTokens: Int = 512,
        temperature: Double = 0.7,
        topP: Double? = nil,
        topK: Int? = nil,
        minP: Double? = nil,
        repetitionPenalty: Double? = nil,
        seed: UInt64? = nil
    ) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.repetitionPenalty = repetitionPenalty
        self.seed = seed
    }

    enum CodingKeys: String, CodingKey {
        case maxTokens
        case temperature
        case topP
        case topK
        case minP
        case repetitionPenalty
        case seed
    }

    enum SnakeCaseCodingKeys: String, CodingKey {
        case maxTokens = "max_tokens"
        case topP = "top_p"
        case topK = "top_k"
        case minP = "min_p"
        case repetitionPenalty = "repetition_penalty"
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
