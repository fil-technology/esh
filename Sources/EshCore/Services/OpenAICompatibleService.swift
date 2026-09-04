import Foundation

public enum OpenAICompatibleError: LocalizedError, Sendable {
    case invalidRequest(String)
    case unsupported(String)
    case notFound(String)
    case methodNotAllowed(String)
    case unauthorized

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let message):
            return message
        case .unsupported(let message):
            return message
        case .notFound(let message):
            return message
        case .methodNotAllowed(let message):
            return message
        case .unauthorized:
            return "Unauthorized."
        }
    }
}

public struct OpenAIChatCompletionsRequest: Codable, Hashable, Sendable {
    public var model: String?
    public var messages: [OpenAIInputMessage]
    public var temperature: Double?
    public var topP: Double?
    public var topK: Int?
    public var minP: Double?
    public var repetitionPenalty: Double?
    public var maxTokens: Int?
    public var maxCompletionTokens: Int?
    public var seed: UInt64?
    public var stream: Bool?
    public var responseFormat: OpenAIResponseFormat?
    public var enableThinking: Bool?
    public var thinkingBudget: Int?
    public var thinkingStartToken: String?
    public var thinkingEndToken: String?
    public var kvBits: Double?
    public var kvQuantScheme: String?
    public var kvGroupSize: Int?
    public var quantizedKVStart: Int?
    public var stop: OpenAIStopSequences?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case topP = "top_p"
        case topK = "top_k"
        case minP = "min_p"
        case repetitionPenalty = "repetition_penalty"
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
        case seed
        case stream
        case responseFormat = "response_format"
        case enableThinking = "enable_thinking"
        case thinkingBudget = "thinking_budget"
        case thinkingStartToken = "thinking_start_token"
        case thinkingEndToken = "thinking_end_token"
        case kvBits = "kv_bits"
        case kvQuantScheme = "kv_quant_scheme"
        case kvGroupSize = "kv_group_size"
        case quantizedKVStart = "quantized_kv_start"
        case stop
    }
}

/// OpenAI `stop` accepts either a single string or an array of strings; normalize both to `[String]`.
public struct OpenAIStopSequences: Codable, Hashable, Sendable {
    public let values: [String]
    public init(_ values: [String]) { self.values = values }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let one = try? c.decode(String.self) { values = one.isEmpty ? [] : [one] }
        else { values = (try? c.decode([String].self)) ?? [] }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(values)
    }
}

public struct OpenAIResponsesRequest: Codable, Hashable, Sendable {
    public var model: String?
    public var input: OpenAIResponsesInput
    public var instructions: String?
    public var temperature: Double?
    public var topP: Double?
    public var topK: Int?
    public var minP: Double?
    public var repetitionPenalty: Double?
    public var maxOutputTokens: Int?
    public var seed: UInt64?
    public var stream: Bool?
    public var responseFormat: OpenAIResponseFormat?
    public var enableThinking: Bool?
    public var thinkingBudget: Int?
    public var thinkingStartToken: String?
    public var thinkingEndToken: String?
    public var kvBits: Double?
    public var kvQuantScheme: String?
    public var kvGroupSize: Int?
    public var quantizedKVStart: Int?
    public var stop: OpenAIStopSequences?

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case instructions
        case temperature
        case topP = "top_p"
        case topK = "top_k"
        case minP = "min_p"
        case repetitionPenalty = "repetition_penalty"
        case maxOutputTokens = "max_output_tokens"
        case seed
        case stream
        case responseFormat = "response_format"
        case enableThinking = "enable_thinking"
        case thinkingBudget = "thinking_budget"
        case thinkingStartToken = "thinking_start_token"
        case thinkingEndToken = "thinking_end_token"
        case kvBits = "kv_bits"
        case kvQuantScheme = "kv_quant_scheme"
        case kvGroupSize = "kv_group_size"
        case quantizedKVStart = "quantized_kv_start"
        case stop
    }
}

public struct OpenAIResponseFormat: Codable, Hashable, Sendable {
    public var type: String
    public var jsonSchema: JSONValue?

    enum CodingKeys: String, CodingKey {
        case type
        case jsonSchema = "json_schema"
    }
}

public enum OpenAIResponsesInput: Codable, Hashable, Sendable {
    case text(String)
    case messages([OpenAIInputMessage])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
            return
        }
        self = .messages(try container.decode([OpenAIInputMessage].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try container.encode(text)
        case .messages(let messages):
            try container.encode(messages)
        }
    }
}

public struct OpenAIInputMessage: Codable, Hashable, Sendable {
    public var role: String
    public var content: OpenAIInputContent
}

public enum OpenAIInputContent: Codable, Hashable, Sendable {
    case text(String)
    case parts([OpenAIInputContentPart])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
            return
        }
        self = .parts(try container.decode([OpenAIInputContentPart].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try container.encode(text)
        case .parts(let parts):
            try container.encode(parts)
        }
    }

    func flattenedText() throws -> String {
        switch self {
        case .text(let text):
            return text
        case .parts(let parts):
            let texts = parts.compactMap { part -> String? in
                guard case .text(let text) = part else {
                    return nil
                }
                return text
            }
            return texts.joined()
        }
    }
}

public enum OpenAIInputContentPart: Codable, Hashable, Sendable {
    case text(String)
    case unsupported

    private enum CodingKeys: String, CodingKey {
        case type
        case text
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text", "input_text", "output_text":
            self = .text(try container.decode(String.self, forKey: .text))
        default:
            self = .unsupported
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .unsupported:
            try container.encode("unsupported", forKey: .type)
        }
    }
}

public struct OpenAIChatCompletionsResponse: Codable, Hashable, Sendable {
    public var id: String
    public var object: String
    public var created: Int
    public var model: String
    public var choices: [Choice]

    public struct Choice: Codable, Hashable, Sendable {
        public var index: Int
        public var message: Message
        public var finishReason: String

        enum CodingKeys: String, CodingKey {
            case index
            case message
            case finishReason = "finish_reason"
        }
    }

    public struct Message: Codable, Hashable, Sendable {
        public var role: String
        public var content: String
    }
}

public struct OpenAIChatCompletionsStreamResponse: Codable, Hashable, Sendable {
    public var id: String
    public var object: String
    public var created: Int
    public var model: String
    public var choices: [Choice]

    public struct Choice: Codable, Hashable, Sendable {
        public var index: Int
        public var delta: Delta
        public var finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index
            case delta
            case finishReason = "finish_reason"
        }
    }

    public struct Delta: Codable, Hashable, Sendable {
        public var role: String?
        public var content: String?
    }
}

public struct OpenAIResponsesResponse: Codable, Hashable, Sendable {
    public var id: String
    public var object: String
    public var createdAt: Int
    public var model: String
    public var output: [OutputItem]
    public var outputText: String

    enum CodingKeys: String, CodingKey {
        case id
        case object
        case createdAt = "created_at"
        case model
        case output
        case outputText = "output_text"
    }

    public struct OutputItem: Codable, Hashable, Sendable {
        public var id: String
        public var type: String
        public var role: String
        public var content: [Content]
    }

    public struct Content: Codable, Hashable, Sendable {
        public var type: String
        public var text: String
        public var annotations: [String]
    }
}

public struct OpenAIResponsesStreamEvent: Codable, Hashable, Sendable {
    public var type: String
    public var sequenceNumber: Int?
    public var itemID: String?
    public var outputIndex: Int?
    public var contentIndex: Int?
    public var delta: String?
    public var text: String?
    public var item: JSONValue?
    public var part: JSONValue?
    public var response: OpenAIResponsesResponse?

    enum CodingKeys: String, CodingKey {
        case type
        case sequenceNumber = "sequence_number"
        case itemID = "item_id"
        case outputIndex = "output_index"
        case contentIndex = "content_index"
        case delta
        case text
        case item
        case part
        case response
    }
}

public enum JSONValue: Codable, Hashable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.typeMismatch(JSONValue.self, .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let object):
            try container.encode(object)
        case .array(let array):
            try container.encode(array)
        case .string(let string):
            try container.encode(string)
        case .int(let int):
            try container.encode(int)
        case .double(let double):
            try container.encode(double)
        case .bool(let bool):
            try container.encode(bool)
        case .null:
            try container.encodeNil()
        }
    }
}

public struct OpenAIModelsResponse: Codable, Hashable, Sendable {
    public var object: String
    public var data: [Model]
    public var models: [Model]

    public init(object: String, data: [Model]) {
        self.object = object
        self.data = data
        self.models = data
    }

    public struct Model: Codable, Hashable, Sendable {
        public var id: String
        public var slug: String
        public var displayName: String
        public var defaultReasoningLevel: String
        public var supportedReasoningLevels: [String]
        public var inputModalities: [String]
        public var supportsPersonality: Bool
        public var additionalSpeedTiers: [String]
        public var isDefault: Bool
        public var shellType: String
        public var visibility: String
        public var supportsReasoningSummaries: Bool
        public var defaultReasoningSummary: String
        public var supportVerbosity: Bool
        public var defaultVerbosity: String
        public var supportsImageDetailOriginal: Bool
        public var contextWindow: Int
        public var maxContextWindow: Int
        public var autoCompactTokenLimit: Int
        public var effectiveContextWindowPercent: Int
        public var experimentalSupportedTools: [String]
        public var supportsSearchTool: Bool
        public var supportedInAPI: Bool
        public var priority: Int
        public var object: String
        public var created: Int
        public var ownedBy: String

        public init(id: String, object: String, created: Int, ownedBy: String) {
            self.id = id
            self.slug = id
            self.displayName = id
            self.defaultReasoningLevel = "medium"
            self.supportedReasoningLevels = []
            self.inputModalities = ["text"]
            self.supportsPersonality = false
            self.additionalSpeedTiers = []
            self.isDefault = false
            self.shellType = "default"
            self.visibility = "list"
            self.supportsReasoningSummaries = false
            self.defaultReasoningSummary = "none"
            self.supportVerbosity = false
            self.defaultVerbosity = "medium"
            self.supportsImageDetailOriginal = false
            self.contextWindow = 32_768
            self.maxContextWindow = 32_768
            self.autoCompactTokenLimit = 28_000
            self.effectiveContextWindowPercent = 100
            self.experimentalSupportedTools = []
            self.supportsSearchTool = false
            self.supportedInAPI = true
            self.priority = 0
            self.object = object
            self.created = created
            self.ownedBy = ownedBy
        }

        enum CodingKeys: String, CodingKey {
            case id
            case slug
            case displayName = "display_name"
            case defaultReasoningLevel = "default_reasoning_level"
            case supportedReasoningLevels = "supported_reasoning_levels"
            case inputModalities = "input_modalities"
            case supportsPersonality = "supports_personality"
            case additionalSpeedTiers = "additional_speed_tiers"
            case isDefault = "is_default"
            case shellType = "shell_type"
            case visibility
            case supportsReasoningSummaries = "supports_reasoning_summaries"
            case defaultReasoningSummary = "default_reasoning_summary"
            case supportVerbosity = "support_verbosity"
            case defaultVerbosity = "default_verbosity"
            case supportsImageDetailOriginal = "supports_image_detail_original"
            case contextWindow = "context_window"
            case maxContextWindow = "max_context_window"
            case autoCompactTokenLimit = "auto_compact_token_limit"
            case effectiveContextWindowPercent = "effective_context_window_percent"
            case experimentalSupportedTools = "experimental_supported_tools"
            case supportsSearchTool = "supports_search_tool"
            case supportedInAPI = "supported_in_api"
            case priority
            case object
            case created
            case ownedBy = "owned_by"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            slug = try container.decodeIfPresent(String.self, forKey: .slug) ?? id
            displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? id
            defaultReasoningLevel = try container.decodeIfPresent(String.self, forKey: .defaultReasoningLevel) ?? "medium"
            supportedReasoningLevels = try container.decodeIfPresent([String].self, forKey: .supportedReasoningLevels) ?? []
            inputModalities = try container.decodeIfPresent([String].self, forKey: .inputModalities) ?? ["text"]
            supportsPersonality = try container.decodeIfPresent(Bool.self, forKey: .supportsPersonality) ?? false
            additionalSpeedTiers = try container.decodeIfPresent([String].self, forKey: .additionalSpeedTiers) ?? []
            isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
            shellType = try container.decodeIfPresent(String.self, forKey: .shellType) ?? "default"
            visibility = try container.decodeIfPresent(String.self, forKey: .visibility) ?? "list"
            supportsReasoningSummaries = try container.decodeIfPresent(Bool.self, forKey: .supportsReasoningSummaries) ?? false
            defaultReasoningSummary = try container.decodeIfPresent(String.self, forKey: .defaultReasoningSummary) ?? "none"
            supportVerbosity = try container.decodeIfPresent(Bool.self, forKey: .supportVerbosity) ?? false
            defaultVerbosity = try container.decodeIfPresent(String.self, forKey: .defaultVerbosity) ?? "medium"
            supportsImageDetailOriginal = try container.decodeIfPresent(Bool.self, forKey: .supportsImageDetailOriginal) ?? false
            contextWindow = try container.decodeIfPresent(Int.self, forKey: .contextWindow) ?? 32_768
            maxContextWindow = try container.decodeIfPresent(Int.self, forKey: .maxContextWindow) ?? contextWindow
            autoCompactTokenLimit = try container.decodeIfPresent(Int.self, forKey: .autoCompactTokenLimit) ?? max(0, contextWindow - 4_768)
            effectiveContextWindowPercent = try container.decodeIfPresent(Int.self, forKey: .effectiveContextWindowPercent) ?? 100
            experimentalSupportedTools = try container.decodeIfPresent([String].self, forKey: .experimentalSupportedTools) ?? []
            supportsSearchTool = try container.decodeIfPresent(Bool.self, forKey: .supportsSearchTool) ?? false
            supportedInAPI = try container.decodeIfPresent(Bool.self, forKey: .supportedInAPI) ?? true
            priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0
            object = try container.decode(String.self, forKey: .object)
            created = try container.decode(Int.self, forKey: .created)
            ownedBy = try container.decode(String.self, forKey: .ownedBy)
        }
    }

    enum CodingKeys: String, CodingKey {
        case object
        case data
        case models
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        object = try container.decode(String.self, forKey: .object)
        data = try container.decodeIfPresent([Model].self, forKey: .data)
            ?? container.decode([Model].self, forKey: .models)
        models = try container.decodeIfPresent([Model].self, forKey: .models) ?? data
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(object, forKey: .object)
        try container.encode(data, forKey: .data)
        try container.encode(models, forKey: .models)
    }
}

public struct OllamaTagsResponse: Codable, Hashable, Sendable {
    public var models: [Model]

    public struct Model: Codable, Hashable, Sendable {
        public var name: String
        public var model: String
        public var modifiedAt: String
        public var size: Int
        public var digest: String
        public var details: Details

        enum CodingKeys: String, CodingKey {
            case name
            case model
            case modifiedAt = "modified_at"
            case size
            case digest
            case details
        }
    }

    public struct Details: Codable, Hashable, Sendable {
        public var format: String
        public var family: String
        public var parameterSize: String
        public var quantizationLevel: String

        enum CodingKeys: String, CodingKey {
            case format
            case family
            case parameterSize = "parameter_size"
            case quantizationLevel = "quantization_level"
        }
    }
}

public struct OpenAIToolsResponse: Codable, Hashable, Sendable {
    public var object: String
    public var data: [Tool]
    public var supportsRequestTools: Bool

    enum CodingKeys: String, CodingKey {
        case object
        case data
        case supportsRequestTools = "supports_request_tools"
    }

    public struct Tool: Codable, Hashable, Sendable {
        public var type: String
        public var function: Function
    }

    public struct Function: Codable, Hashable, Sendable {
        public var name: String
        public var description: String
        public var parameters: [String: String]
    }
}

public struct OpenAIAudioModelsResponse: Codable, Hashable, Sendable {
    public var object: String
    public var data: [OpenAIAudioModel]
}

public struct OpenAIAudioSpeechRequest: Codable, Hashable, Sendable {
    public var model: String?
    public var input: String
    public var voice: String?
    public var language: String?
    public var responseFormat: String?
    public var maxTokens: Int?
    public var temperature: Double?
    public var topP: Double?

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case voice
        case language
        case responseFormat = "response_format"
        case maxTokens = "max_tokens"
        case temperature
        case topP = "top_p"
    }
}

public struct OpenAIAudioTranscriptionRequest: Codable, Hashable, Sendable {
    /// Base64-encoded audio bytes (WAV/MP3/etc). The browser client posts this from a FileReader
    /// data URL (the part after the comma).
    public var audio: String
    public var model: String?
    public var language: String?
    public var filename: String?

    enum CodingKeys: String, CodingKey {
        case audio
        case model
        case language
        case filename
    }
}

public struct OpenAIAudioTranscriptionResponse: Codable, Hashable, Sendable {
    public var text: String
    public var model: String?
    public var language: String?

    public init(text: String, model: String? = nil, language: String? = nil) {
        self.text = text
        self.model = model
        self.language = language
    }
}

public struct OpenAIAudioSpeechResponse: Hashable, Sendable {
    public var audioData: Data
    public var contentType: String
    public var filename: String
    public var modelID: String
    public var sampleRate: Int

    public init(
        audioData: Data,
        contentType: String = "audio/wav",
        filename: String,
        modelID: String,
        sampleRate: Int
    ) {
        self.audioData = audioData
        self.contentType = contentType
        self.filename = filename
        self.modelID = modelID
        self.sampleRate = sampleRate
    }
}

public struct OpenAIAudioModel: Codable, Hashable, Sendable {
    public var id: String
    public var object: String
    public var created: Int
    public var ownedBy: String
    public var displayName: String
    public var voices: [Voice]
    public var languages: [Language]
    public var outputFormats: [String]
    public var capabilities: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case object
        case created
        case ownedBy = "owned_by"
        case displayName = "display_name"
        case voices
        case languages
        case outputFormats = "output_formats"
        case capabilities
    }

    public init(
        id: String,
        object: String = "model",
        created: Int = 0,
        ownedBy: String = "esh-audio",
        displayName: String,
        voices: [Voice],
        languages: [Language],
        outputFormats: [String] = ["wav"],
        capabilities: [String] = ["tts"]
    ) {
        self.id = id
        self.object = object
        self.created = created
        self.ownedBy = ownedBy
        self.displayName = displayName
        self.voices = voices
        self.languages = languages
        self.outputFormats = outputFormats
        self.capabilities = capabilities
    }

    public struct Voice: Codable, Hashable, Sendable {
        public var id: String
        public var displayName: String?

        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
        }

        public init(id: String, displayName: String? = nil) {
            self.id = id
            self.displayName = displayName
        }
    }

    public struct Language: Codable, Hashable, Sendable {
        public var id: String
        public var displayName: String?

        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
        }

        public init(id: String, displayName: String? = nil) {
            self.id = id
            self.displayName = displayName
        }
    }
}

public struct OpenAIErrorResponse: Codable, Hashable, Sendable {
    public var error: ErrorBody

    public struct ErrorBody: Codable, Hashable, Sendable {
        public var message: String
        public var type: String
    }
}

/// A request to a 2.0 Web Experience data endpoint. The esh executable's provider switches on
/// `path` and composes JSON from the canonical services.
public struct WebDataRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var body: Data

    public init(method: String, path: String, query: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
    }
}

public struct OpenAICompatibleService: Sendable {
    private let inferClosure: @Sendable (ExternalInferenceRequest) async throws -> ExternalInferenceResponse
    /// Optional incremental token stream; when present, streaming chat completions emit real per-token
    /// SSE deltas instead of chunking a fully-generated response.
    private let streamClosure: (@Sendable (ExternalInferenceRequest) -> AsyncThrowingStream<String, Error>)?
    private let installedModelsClosure: @Sendable () throws -> [ExternalInstalledModelCapability]
    private let audioModelsClosure: @Sendable () throws -> [OpenAIAudioModel]
    private let speechClosure: @Sendable (OpenAIAudioSpeechRequest) async throws -> OpenAIAudioSpeechResponse
    /// Optional speech-to-text (STT). When present, POST /v1/audio/transcriptions transcribes posted
    /// audio bytes; when nil the route reports that no speech model is available.
    private let transcribeClosure: (@Sendable (OpenAIAudioTranscriptionRequest) async throws -> OpenAIAudioTranscriptionResponse)?
    /// Optional provider for the 2.0 Web Experience data endpoints (engine status, schedule/why,
    /// catalog+fit, config). Returns raw JSON so the esh executable composes it from the canonical
    /// services (thin-client rule: no runtime/policy logic in the web layer or the browser).
    private let webDataClosure: (@Sendable (WebDataRequest) async throws -> Data)?
    /// UCMR (2.1): optional capability execution (POST /v1/execute) and artifact serving
    /// (GET /v1/artifacts/{id}). Additive; nil in processes that don't wire the capability runtime.
    private let executeClosure: (@Sendable (ExecutionRequest) async throws -> ExecutionResult)?
    private let artifactClosure: (@Sendable (UUID, String?) async throws -> ArtifactBytes?)?
    /// UCMR 2.1 Capability Intent Router: POST /v1/route (message+attachments → RouteDecision) and
    /// /v1/route/resume (pendingId → RouteDecision). Additive; nil when the router isn't wired.
    private let routeClosure: (@Sendable (String, [EshAttachment], String?) async -> RouteDecision)?
    private let resumeRouteClosure: (@Sendable (String, String?) async -> RouteDecision)?
    /// Router Auto benchmark (POST /v1/route/benchmark?mode=tier0|tier1|hybrid): runs the routing dataset,
    /// persists versioned evidence, returns metrics JSON. Additive; nil when the router isn't wired.
    private let routeBenchmarkClosure: (@Sendable (String) async -> Data)?
    /// Per-case routing detail for failure analysis (POST /v1/route/benchmark/detail?mode=…). Additive.
    private let routeBenchmarkDetailClosure: (@Sendable (String) async -> Data)?
    /// image.upscale performance benchmark (POST /v1/capability/image-upscale/benchmark) — measures real
    /// cold/warm/memory on this Mac and persists unified evidence. Additive; nil when not wired.
    private let upscaleBenchmarkClosure: (@Sendable () async -> Data)?

    public init(
        infer: @escaping @Sendable (ExternalInferenceRequest) async throws -> ExternalInferenceResponse,
        stream: (@Sendable (ExternalInferenceRequest) -> AsyncThrowingStream<String, Error>)? = nil,
        installedModels: @escaping @Sendable () throws -> [ExternalInstalledModelCapability],
        audioModels: @escaping @Sendable () throws -> [OpenAIAudioModel] = { [] },
        speech: @escaping @Sendable (OpenAIAudioSpeechRequest) async throws -> OpenAIAudioSpeechResponse = { _ in
            throw OpenAICompatibleError.unsupported("Audio speech generation is not available in this process.")
        },
        transcribe: (@Sendable (OpenAIAudioTranscriptionRequest) async throws -> OpenAIAudioTranscriptionResponse)? = nil,
        webData: (@Sendable (WebDataRequest) async throws -> Data)? = nil,
        execute: (@Sendable (ExecutionRequest) async throws -> ExecutionResult)? = nil,
        artifact: (@Sendable (UUID, String?) async throws -> ArtifactBytes?)? = nil,
        route: (@Sendable (String, [EshAttachment], String?) async -> RouteDecision)? = nil,
        resumeRoute: (@Sendable (String, String?) async -> RouteDecision)? = nil,
        routeBenchmark: (@Sendable (String) async -> Data)? = nil,
        routeBenchmarkDetail: (@Sendable (String) async -> Data)? = nil,
        upscaleBenchmark: (@Sendable () async -> Data)? = nil
    ) {
        self.inferClosure = infer
        self.streamClosure = stream
        self.installedModelsClosure = installedModels
        self.audioModelsClosure = audioModels
        self.speechClosure = speech
        self.transcribeClosure = transcribe
        self.webDataClosure = webData
        self.executeClosure = execute
        self.artifactClosure = artifact
        self.routeClosure = route
        self.resumeRouteClosure = resumeRoute
        self.routeBenchmarkClosure = routeBenchmark
        self.routeBenchmarkDetailClosure = routeBenchmarkDetail
        self.upscaleBenchmarkClosure = upscaleBenchmark
    }

    /// Run the image.upscale performance benchmark and return measured evidence JSON.
    public func runUpscaleBenchmark() async throws -> Data {
        guard let upscaleBenchmarkClosure else { throw OpenAICompatibleError.unsupported("Upscale benchmarking is not available in this process.") }
        return await upscaleBenchmarkClosure()
    }

    /// Run the Router Auto benchmark for a mode and return metrics JSON (POST /v1/route/benchmark).
    public func routeBenchmark(mode: String) async throws -> Data {
        guard let routeBenchmarkClosure else { throw OpenAICompatibleError.unsupported("Router benchmarking is not available in this process.") }
        return await routeBenchmarkClosure(mode)
    }

    /// Per-case routing detail for one mode (POST /v1/route/benchmark/detail) — for failure analysis.
    public func routeBenchmarkDetail(mode: String) async throws -> Data {
        guard let routeBenchmarkDetailClosure else { throw OpenAICompatibleError.unsupported("Router benchmarking is not available in this process.") }
        return await routeBenchmarkDetailClosure(mode)
    }

    /// Route a chat message + typed attachments to a capability decision (POST /v1/route).
    public func route(message: String, attachments: [EshAttachment], conversationID: String?) async throws -> RouteDecision {
        guard let routeClosure else { throw OpenAICompatibleError.unsupported("Capability routing is not available in this process.") }
        return await routeClosure(message, attachments, conversationID)
    }

    /// Resume a pending capability invocation after its component was installed (POST /v1/route/resume).
    public func resumeRoute(pendingId: String, conversationID: String?) async throws -> RouteDecision {
        guard let resumeRouteClosure else { throw OpenAICompatibleError.unsupported("Capability routing is not available in this process.") }
        return await resumeRouteClosure(pendingId, conversationID)
    }

    /// Run a capability request (POST /v1/execute).
    public func execute(_ request: ExecutionRequest) async throws -> ExecutionResult {
        guard let executeClosure else {
            throw OpenAICompatibleError.unsupported("Capability execution is not available in this process.")
        }
        return try await executeClosure(request)
    }

    /// Fetch a generated artifact's bytes (GET /v1/artifacts/{id}[/{file}]).
    public func artifactBytes(id: UUID, file: String?) async throws -> ArtifactBytes? {
        guard let artifactClosure else {
            throw OpenAICompatibleError.unsupported("Artifact serving is not available in this process.")
        }
        return try await artifactClosure(id, file)
    }

    /// Build the warm-model pool the server uses. Exposed so a caller that also runs a persistent
    /// speech runtime can construct ONE manager and hand the same instance to both this service and the
    /// `SpeechRuntimeManager`, so LLMs and speech share a single memory budget (M12 follow-up).
    /// Safe default Content-Security-Policy for previewable web artifacts. Deliberately does NOT constrain
    /// script-src/style-src/img-src — the preview iframe already runs at an OPAQUE origin (sandbox without
    /// allow-same-origin), so a `'self'` source would fail to match and break loading the bundle's own
    /// relative CSS/JS, and single-file webArtifacts legitimately rely on inline <script>/<style>. Instead we
    /// block the genuinely dangerous vectors with zero regression risk: no network egress (connect-src),
    /// no plugins (object-src), no <base> hijack (base-uri), and only same-origin framing (frame-ancestors).
    /// A Tier-B managed project that needs a data feed overrides this via its PreviewConfig.csp allowlist.
    static let defaultArtifactCSP = "connect-src 'none'; object-src 'none'; base-uri 'none'; frame-ancestors 'self'"

    /// Content type for a project file, derived from its extension. Falls back to the artifact's own
    /// mime for html/unknown so a single-file webArtifact keeps behaving exactly as before.
    static func contentType(for path: String, default fallback: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "txt", "md": return "text/plain; charset=utf-8"
        default: return fallback
        }
    }

    public static func makeLifecycleManager(registry: InferenceBackendRegistry = .init()) -> RuntimeLifecycleManager {
        let host = HostMachineProfileService().currentProfile()
        // Persistent MLX residency (opt-in until benchmarks justify making it the default). When on,
        // MLX installs load through a persistent, weights-resident worker owned by this same
        // lifecycle manager; everything else keeps the per-request runtime.
        let persistentMLX = ProcessInfo.processInfo.environment["ESH_MLX_PERSISTENT"] == "1"
        return RuntimeLifecycleManager(
            usableBudgetGB: host.totalMemoryGB.map { max(1, $0 - 3) },
            estimator: { install in max(0.2, Double(install.sizeBytes) / 1_073_741_824 * 1.3) },
            loader: { install in
                if persistentMLX, install.spec.backend == .mlx {
                    return try await MLXBackend(persistent: true).loadRuntime(for: install)
                }
                return try await registry.backend(for: install).loadRuntime(for: install)
            },
            residencyProbe: { install in
                (persistentMLX && install.spec.backend == .mlx) ? .weightsResident : .handleCached
            }
        )
    }

    public init(
        modelStore: ModelStore,
        sessionStore: SessionStore,
        cacheStore: CacheStore,
        toolVersion: String? = nil,
        registry: InferenceBackendRegistry = .init(),
        workspaceRootURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        audioModels: @escaping @Sendable () throws -> [OpenAIAudioModel] = { [] },
        speech: @escaping @Sendable (OpenAIAudioSpeechRequest) async throws -> OpenAIAudioSpeechResponse = { _ in
            throw OpenAICompatibleError.unsupported("Audio speech generation is not available in this process.")
        },
        transcribe: (@Sendable (OpenAIAudioTranscriptionRequest) async throws -> OpenAIAudioTranscriptionResponse)? = nil,
        webData: (@Sendable (WebDataRequest) async throws -> Data)? = nil,
        lifecycleManager: RuntimeLifecycleManager? = nil,
        root: PersistenceRoot? = nil,
        artifactStore: ArtifactStore? = nil
    ) {
        // M7: the server is long-lived, so give it a warm pool. Model runtimes acquired for one
        // request stay warm and are reused by the next, evicted on idle/memory pressure.
        // M12 follow-up: callers that also run a persistent speech runtime pass a shared manager (built
        // via `makeLifecycleManager`) so speech and LLMs share one memory budget; otherwise build one.
        let lifecycleManager = lifecycleManager ?? Self.makeLifecycleManager(registry: registry)
        let inference = ExternalInferenceService(
            modelStore: modelStore,
            sessionStore: sessionStore,
            cacheStore: cacheStore,
            registry: registry,
            lifecycleManager: lifecycleManager,
            workspaceRootURL: workspaceRootURL
        )
        let capabilities = ExternalCapabilitiesService(modelStore: modelStore)

        // UCMR (2.1): when a root + artifact store are provided, wire the capability runtime so
        // POST /v1/execute and GET /v1/artifacts work. Stage 0 registers the language.generate provider
        // (bridging to the existing text stream); non-text providers are added in later stages.
        var executeClosure: (@Sendable (ExecutionRequest) async throws -> ExecutionResult)?
        var artifactClosure: (@Sendable (UUID, String?) async throws -> ArtifactBytes?)?
        var routeClosure: (@Sendable (String, [EshAttachment], String?) async -> RouteDecision)?
        var resumeRouteClosure: (@Sendable (String, String?) async -> RouteDecision)?
        var routeBenchmarkClosure: (@Sendable (String) async -> Data)?
        var routeBenchmarkDetailClosure: (@Sendable (String) async -> Data)?
        var upscaleBenchmarkClosure: (@Sendable () async -> Data)?
        if let root, let artifactStore {
            var registryUCMR = CapabilityRegistry()
            registryUCMR.register(LanguageGenerateProvider(stream: { req in inference.inferStream(request: req) }))
            // vector.generate (text→SVG): a small resident model often fails to emit clean JSON. Give the
            // provider a repair pass + escalation to Apple Intelligence (on-device, JSON-reliable) when it's
            // available. Auto is quality-first (Apple FM first); a user-pinned model takes precedence.
            let svgConfigRoot = root
            var svgStrong: TextToSVGProvider.StrongInferFn? = nil
            if AppleIntelligenceService().status().available {
                svgStrong = { sys, user, _ in
                    let text = try await AppleIntelligenceService().generate(prompt: user, instructions: sys)
                    return (text, "apple-intelligence")
                }
            }
            registryUCMR.register(TextToSVGProvider(
                infer: { req in try await inference.infer(request: req) },
                strongInfer: svgStrong,
                preferStrongFirst: {
                    let pick = (try? EshConfigStore(root: svgConfigRoot).load())?.defaults.capabilityModels["vector.generate"] ?? ""
                    return pick.isEmpty || pick == "auto"   // Auto → quality-first; a pin → the pinned model first
                }))
            // webArtifact.generate (text → self-contained HTML): same quality-first + repair + Apple-FM
            // escalation as SVG, previewed in an isolated sandbox. LLM codegen — no heavy models.
            registryUCMR.register(WebArtifactProvider(
                infer: { req in try await inference.infer(request: req) },
                strongInfer: svgStrong,
                preferStrongFirst: {
                    let pick = (try? EshConfigStore(root: svgConfigRoot).load())?.defaults.capabilityModels["webArtifact.generate"] ?? ""
                    return pick.isEmpty || pick == "auto"
                }))
            // project.generate (text → multi-file static web project). Same LLM-codegen pattern; static
            // preview (no npm/build/dev-server — the managed runtime tier is deferred).
            registryUCMR.register(ProjectGenProvider(
                infer: { req in try await inference.infer(request: req) },
                strongInfer: svgStrong,
                preferStrongFirst: {
                    let pick = (try? EshConfigStore(root: svgConfigRoot).load())?.defaults.capabilityModels["project.generate"] ?? ""
                    return pick.isEmpty || pick == "auto"
                },
                // Tier-B (browser-native) prefers the best installed local coding model over Apple FM; resolved
                // from the live catalog by metadata (no hard-coded id). nil → fall back to Apple FM/default.
                codingModel: { ProjectGenProvider.bestCodingModelID((try? modelStore.listInstalls()) ?? []) }))
            // Embeddings + reranking ride the already-bundled llama-server (--embeddings / --reranking).
            let auxRuntime = LlamaAuxRuntimeManager(resolve: { modelID in
                guard let id = modelID else { throw CapabilityError.failed("embeddings/rerank require an explicit model id") }
                let backend = LlamaCppBackend()
                let exe = try backend.resolveExecutable()
                guard let install = (try modelStore.listInstalls()).first(where: { $0.id == id }) else {
                    throw CapabilityError.failed("Model not installed: \(id)")
                }
                return (exe, try backend.locateModelFile(for: install).path)
            })
            registryUCMR.register(EmbeddingProvider(embed: { modelID, texts in try await auxRuntime.embed(modelID: modelID, texts: texts) }))
            registryUCMR.register(RerankProvider(rerank: { modelID, query, docs in try await auxRuntime.rerank(modelID: modelID, query: query, documents: docs) }))
            // Vision understanding (image + text -> text) via mlx-vlm.
            let visionService = VisionUnderstandingService()
            registryUCMR.register(VisionUnderstandProvider(understand: { paths, prompt, model, maxTokens in
                // Prefer the local install path so mlx-vlm loads from disk instead of treating an install id
                // (e.g. "mlx-community--nanollava-1.5-4bit", which has "--") as a HF repo id and failing.
                let installs = (try? modelStore.listInstalls()) ?? []
                let modelPath = installs.first(where: { $0.id == model })?.installPath ?? model
                return try visionService.understand(imagePaths: paths, prompt: prompt, model: modelPath, maxTokens: maxTokens)
            }))
            // OCR via Apple Vision (zero dependency, on-device, no model).
            registryUCMR.register(AppleVisionOCRProvider())
            // Background removal / segmentation via rembg (optional dependency).
            let segmentationService = SegmentationService()
            registryUCMR.register(SegmentationProvider(removeBackground: { inPath, outPath in
                try segmentationService.removeBackground(imagePath: inPath, outputPath: outPath)
            }))
            // Text -> image generation via mflux Z-Image Turbo (optional dependency).
            let imageGenService = ImageGenerationService()
            registryUCMR.register(ImageGenerationProvider(generate: { prompt, outPath, steps, seed, w, h, q, minFree, hfCache in
                try imageGenService.generate(prompt: prompt, outputPath: outPath, steps: steps, seed: seed,
                                             width: w, height: h, quantize: q, minFreeMemMB: minFree, hfCache: hfCache)
            }))
            // Instruction-based image editing (image + instruction → image). Default backend: Qwen-Image-Edit
            // (Apache-2.0, commercial-safe); FLUX.1 Kontext selectable but experimental/non-commercial.
            let imageEditService = ImageEditService()
            registryUCMR.register(ImageEditProvider(edit: { inPath, outPath, instruction, backend, model, quantize, minFree, hfCache in
                try imageEditService.edit(imagePath: inPath, outputPath: outPath, instruction: instruction,
                                          backend: backend, model: model, quantize: quantize, minFreeMemMB: minFree, hfCache: hfCache)
            }))
            // Image super-resolution / upscale. Default backend: Real-ESRGAN ONNX (onnxruntime, torch-free,
            // model auto-downloaded to the assets root). SeedVR2 (mflux) remains selectable but experimental.
            let imageUpscaleService = ImageUpscaleService()
            let upscaleModelDir = root.cachesURL.appendingPathComponent("upscale-models", isDirectory: true).path
            registryUCMR.register(ImageUpscaleProvider(upscale: { inPath, outPath, scale, minFree, backend in
                try imageUpscaleService.upscale(imagePath: inPath, outputPath: outPath, scale: scale,
                                                modelDir: upscaleModelDir, minFreeMemMB: minFree, backend: backend)
            }))
            // Speaker diarization (audio -> structured speaker clusters) via sherpa-onnx (optional dep).
            // Models live under the assets root (audio/diarization-models); absent -> a clear error.
            let diarizationService = DiarizationService()
            let diarModelsDir = root.audioURL.appendingPathComponent("diarization-models", isDirectory: true)
            registryUCMR.register(AudioDiarizationProvider(
                diarize: { audioPath, numSpeakers in
                    try diarizationService.diarize(
                        audioPath: audioPath,
                        segModel: diarModelsDir.appendingPathComponent("segmentation.onnx").path,
                        embModel: diarModelsDir.appendingPathComponent("embedding.onnx").path,
                        numSpeakers: numSpeakers, clusterThreshold: 0.5)
                },
                transcribe: { audioPath in try SpeechToTextService().transcribe(audioPath: audioPath) }))
            // Video understanding — a multi-provider pipeline: native keyframe/audio extraction (AVFoundation)
            // → VLM per frame + STT → LLM fusion. Reuses the vision + STT + text providers; no core surgery.
            var videoStrongFuse: VideoUnderstandingProvider.StrongFuseFn? = nil
            if AppleIntelligenceService().status().available {
                videoStrongFuse = { sys, user, _ in
                    let text = try await AppleIntelligenceService().generate(prompt: user, instructions: sys)
                    return (text, "apple-intelligence")
                }
            }
            let videoVisionResolver = CapabilityModelResolver()
            registryUCMR.register(VideoUnderstandingProvider(
                extractor: AVFoundationVideoExtractor(),
                describeFrame: { imagePath, prompt, explicitModel in
                    let installs = (try? modelStore.listInstalls()) ?? []
                    // Prefer an explicitly-requested vision model (option "visionModel"); else the user's
                    // Vision pin (Settings → Models); else capability-resolve.
                    let visionPin: String? = {
                        let p = (try? EshConfigStore(root: root).load())?.defaults.capabilityModels["image.understand"] ?? ""
                        return (!p.isEmpty && p != "auto" && installs.contains(where: { $0.id == p })) ? p : nil
                    }()
                    guard let vm = explicitModel ?? visionPin ?? videoVisionResolver.resolveModelID(capability: .imageUnderstand, from: installs) else {
                        throw CapabilityError.failed("no vision model for video understanding (pass options.visionModel or install a vision-capable model)")
                    }
                    // Use the local install path so mlx-vlm loads weights from disk instead of trying to
                    // download the repo (which fails on id case/format mismatches).
                    let modelPath = installs.first(where: { $0.id == vm })?.installPath ?? vm
                    return try visionService.understand(imagePaths: [imagePath], prompt: prompt, model: modelPath, maxTokens: 64)
                },
                transcribe: { audioPath in try SpeechToTextService().transcribe(audioPath: audioPath) },
                fuse: { req in try await inference.infer(request: req) },
                // Prefer Apple Intelligence for the fusion summary when available — reliable, no control-token
                // leaks that small resident models produce. Falls back to the resident model otherwise.
                strongFuse: videoStrongFuse))
            let execCtx = ExecutionContext(root: root, artifactStore: artifactStore, lifecycle: lifecycleManager)
            // Capability-aware model resolution: fill `model` from installed models' declared capabilities
            // when a request omits it (Auto across modalities).
            let capabilityResolver = CapabilityModelResolver()
            // Stage 4.2c: performance-aware Auto — feed recorded capability benchmarks so Auto avoids
            // "fits in memory but impractically slow" (e.g. prefers a within-budget resolution for
            // interactive image generation). candidateModels is empty for now (cross-model ranking activates
            // once multiple capable models are installed); the interactive config-preference is active.
            let capabilityScheduler = CapabilityScheduler(index: CapabilityEvidenceIndex(root: root))
            let execSvc = CapabilityExecutionService(registry: registryUCMR, context: execCtx,
                modelResolver: { req in
                    let installs = (try? modelStore.listInstalls()) ?? []
                    // Per-capability model override (Settings → Models → Task models). Honored only when the
                    // pinned model is actually installed; otherwise fall back to capability-aware Auto.
                    let overrides = (try? EshConfigStore(root: root).load())?.defaults.capabilityModels ?? [:]
                    if let pick = overrides[req.capability.rawValue], !pick.isEmpty, pick != "auto",
                       installs.contains(where: { $0.id == pick }) {
                        return pick
                    }
                    return capabilityResolver.resolveModelID(capability: req.capability, from: installs)
                },
                scheduler: capabilityScheduler,
                candidateModels: { _ in [] })
            executeClosure = { req in try await execSvc.executeCollecting(req) }
            // Capability Intent Router (spec 86eyucfbu): message + attachments → RouteDecision, with an
            // in-memory Install-and-Resume store. Uses the live registry + installs + assets root.
            let routerStore = PendingInvocationStore()
            let routerRegistry = registryUCMR   // immutable snapshot after all providers are registered
            // Tier-1 semantic router: a resident LLM proposes a constrained intent when Tier 0 is unsure
            // (ambiguous). Its output is validated against the registry before anything runs (§4/§8).
            let residentRouter = ResidentLLMSemanticRouter(infer: { req in try await inference.infer(request: req) })
            // Router Auto: attach a Tier-1 semantic router to the LIVE resolver ONLY when persisted evidence
            // shows one is safe AND beats the free/instant Tier-0 baseline. With no such evidence (default),
            // live routing stays Tier-0 + clarification — no wasted LLM-escalation latency. (spec §8/§9)
            let autoOS = ProcessInfo.processInfo.operatingSystemVersionString
            let autoDecision = RouterAutoPolicy().choose(
                from: RouterEvidenceStore(root: root).load().evidence,
                currentSchemaVersion: CapabilitySchemaVersion.current,
                currentDatasetVersion: RoutingBenchmark.datasetVersion, currentOS: autoOS)
            let liveSemantic: SemanticIntentRouter? = {
                switch autoDecision.chosenRouter {
                case "resident-llm": return residentRouter
                case "apple-foundation": return AppleFMSemanticRouter()
                case "functiongemma":
                    if let id = (try? modelStore.listInstalls())?.first(where: { $0.id.contains("functiongemma") })?.id {
                        return ResidentLLMSemanticRouter(name: "functiongemma", modelID: id, infer: { req in try await inference.infer(request: req) })
                    }
                    return nil
                default: return nil
                }
            }()
            let semanticRouter = residentRouter
            let routerService = CapabilityRouterService(
                resolver: IntentResolver(semantic: liveSemantic),
                store: routerStore,
                registry: { routerRegistry },
                installs: { (try? modelStore.listInstalls()) ?? [] },
                root: root,
                host: { HostMachineProfileService().currentProfile() },
                semantic: semanticRouter)
            routeClosure = { message, attachments, convo in await routerService.route(message: message, attachments: attachments, conversationID: convo) }
            resumeRouteClosure = { pendingId, convo in await routerService.resume(pendingId: pendingId, conversationID: convo) }
            let benchRoot = root
            routeBenchmarkClosure = { mode in
                // Resolve the requested mode to (router name, benchmark logic mode, optional router override).
                // "…-hybrid" = Tier-0 + escalate-on-clarify; "…-hybrid-gated" additionally gates escalation to
                // `unresolved` clarifies + a Safety Validator (spec: ambiguity-gated Router Auto).
                let gated = mode.contains("gated")
                let hybrid = mode.contains("hybrid")
                let benchMode = mode == "tier0" ? "tier0" : (gated ? mode : (hybrid ? "hybrid" : "tier1"))
                var routerName = "resident-llm"
                var override: SemanticIntentRouter? = nil
                if mode == "tier0" { routerName = "tier0" }
                else if mode.hasPrefix("apple") { routerName = "apple-foundation"; override = AppleFMSemanticRouter() }
                else if mode.hasPrefix("gemma") {
                    routerName = "functiongemma"
                    if let id = (try? modelStore.listInstalls())?.first(where: { $0.id.contains("functiongemma") })?.id {
                        override = ResidentLLMSemanticRouter(name: "functiongemma", modelID: id, infer: { req in try await inference.infer(request: req) })
                    }
                }
                let (m, warm, cold) = await routerService.benchmark(mode: benchMode, semanticOverride: override)
                let hostP = HostMachineProfileService().currentProfile()
                // Distinct evidence key so gated/ungated hybrids and pure tiers never overwrite each other (§8).
                let evMode = mode == "tier0" ? "tier0" : (gated ? "hybrid-gated" : (hybrid ? "hybrid" : "tier1"))
                // downloadMB: extra bytes a router must fetch beyond what's already resident (provenance §13).
                let downloadMB: Int? = mode.hasPrefix("gemma") ? 318 : (mode.hasPrefix("apple") || mode == "tier0" ? 0 : 0)
                let ev = RouterEvidence(
                    router: routerName, mode: evMode, available: true,
                    modelOrProvider: routerName, runtime: mode == "tier0" ? "rules" : (mode.hasPrefix("apple") ? "apple-foundation" : "mlx"),
                    total: m.total, capabilitySelectionAccuracy: m.capabilitySelectionAccuracy, falseExecutionRate: m.falseExecutionRate,
                    conservativeScore: m.conservativeScore, clarifyRecall: m.clarifyRecall, argumentAccuracy: m.argumentAccuracy,
                    enAccuracy: m.languageActionAccuracy("en"), ruAccuracy: m.languageActionAccuracy("ru"), heAccuracy: m.languageActionAccuracy("he"),
                    warmLatencyMsMedian: warm, coldLatencyMs: cold, downloadMB: downloadMB,
                    hardware: hostP.chipDescription ?? "Apple Silicon",
                    osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                    eshVersion: toolVersion, capabilitySchemaVersion: CapabilitySchemaVersion.current,
                    datasetVersion: RoutingBenchmark.datasetVersion, dateISO8601: ISO8601DateFormatter().string(from: Date()))
                try? RouterEvidenceStore(root: benchRoot).upsert(ev)
                let out: [String: JSONValue] = ["mode": .string(mode), "router": .string(routerName), "total": .int(m.total),
                    "capabilityAccuracy": .double(m.capabilitySelectionAccuracy), "falseExecutionRate": .double(m.falseExecutionRate),
                    "conservativeScore": .double(m.conservativeScore), "argumentAccuracy": .double(m.argumentAccuracy),
                    "en": .double(m.languageActionAccuracy("en")), "ru": .double(m.languageActionAccuracy("ru")), "he": .double(m.languageActionAccuracy("he")),
                    "warmLatencyMs": .double(warm ?? 0), "coldLatencyMs": .double(cold ?? 0),
                    "missed": .int(m.missedCapability), "unnecessaryClarify": .int(m.unnecessaryClarification)]
                return (try? JSONCoding.encoder.encode(out)) ?? Data("{}".utf8)
            }
            // Per-case detail for failure analysis (same mode→router mapping as the benchmark above).
            routeBenchmarkDetailClosure = { mode in
                let gated = mode.contains("gated")
                let hybrid = mode.contains("hybrid")
                let benchMode = mode == "tier0" ? "tier0" : (gated ? mode : (hybrid ? "hybrid" : "tier1"))
                var override: SemanticIntentRouter? = nil
                if mode.hasPrefix("apple") { override = AppleFMSemanticRouter() }
                else if mode.hasPrefix("gemma"), let id = (try? modelStore.listInstalls())?.first(where: { $0.id.contains("functiongemma") })?.id {
                    override = ResidentLLMSemanticRouter(name: "functiongemma", modelID: id, infer: { req in try await inference.infer(request: req) })
                }
                let results = await routerService.benchmarkDetail(mode: benchMode, semanticOverride: override)
                return (try? JSONCoding.encoder.encode(RouterBenchmarkDetail(mode: mode, cases: results))) ?? Data("{}".utf8)
            }
            // image.upscale performance benchmark: realistic sizes × scales (avoids absurd combos like 2048@4×).
            let upscaleBenchRoot = root
            upscaleBenchmarkClosure = {
                let dir = upscaleBenchRoot.cachesURL.appendingPathComponent("upscale-models", isDirectory: true).path
                let runner = ImageUpscaleBenchmarkRunner(service: ImageUpscaleService(), modelDir: dir)
                let configs: [ImageUpscaleBenchmarkRunner.Config] = [
                    .init(width: 512, scale: 2), .init(width: 512, scale: 4),
                    .init(width: 1024, scale: 2), .init(width: 1024, scale: 4),
                    .init(width: 2048, scale: 2)]
                let tmp = upscaleBenchRoot.tempURL.appendingPathComponent("upscale-bench", isDirectory: true)
                let host = HostMachineProfileService().currentProfile()
                let evidence = await Task.detached { () -> [CapabilityPerformanceEvidence] in
                    runner.run(configs: configs, tmpDir: tmp, provenanceNote: host.chipDescription)
                }.value
                let store = ImageUpscaleBenchmarkStore(root: upscaleBenchRoot)
                for e in evidence { try? store.upsert(e) }
                try? FileManager.default.removeItem(at: tmp)
                return (try? JSONCoding.encoder.encode(UpscaleBenchmarkDataset(evidence: evidence))) ?? Data("{}".utf8)
            }
            artifactClosure = { id, file in
                guard let artifact = try artifactStore.load(id: id) else { return nil }
                let target = file ?? artifact.entrypoint ?? artifact.files.first?.relativePath
                guard let target, let data = try artifactStore.data(id: id, file: target) else { return nil }
                let isKnownFile = artifact.files.first(where: { $0.relativePath == target }) != nil
                // Serve each project file with the content type its extension implies — a multi-file
                // webProject's style.css / script.js must NOT inherit the artifact's text/html, or a strict
                // (nosniff) browser refuses to apply the stylesheet and to execute the script.
                let mime = isKnownFile ? Self.contentType(for: target, default: artifact.mimeType) : "application/octet-stream"
                // Defense-in-depth CSP for previewable web artifacts: a v2 project may pin its own policy
                // (PreviewConfig.csp, e.g. a network allowlist); otherwise apply the safe default. Non-web
                // artifacts (image/svg/audio/…) get no CSP.
                var csp: String? = nil
                if artifact.kind == .webProject {
                    csp = ProjectManifestV2.from(metadata: artifact.metadata)?.previewConfiguration.csp
                        ?? Self.defaultArtifactCSP
                }
                return ArtifactBytes(data: data, mimeType: mime, filename: (target as NSString).lastPathComponent,
                                     contentSecurityPolicy: csp)
            }
        }

        self.init(
            infer: { request in
                try await inference.infer(request: request)
            },
            stream: { request in
                inference.inferStream(request: request)
            },
            installedModels: {
                try capabilities.describe(toolVersion: toolVersion).installedModels
            },
            audioModels: audioModels,
            speech: speech,
            transcribe: transcribe,
            webData: webData,
            execute: executeClosure,
            artifact: artifactClosure,
            route: routeClosure,
            resumeRoute: resumeRouteClosure,
            routeBenchmark: routeBenchmarkClosure,
            routeBenchmarkDetail: routeBenchmarkDetailClosure,
            upscaleBenchmark: upscaleBenchmarkClosure
        )
    }

    /// Serve a 2.0 Web Experience data endpoint (engine/schedule/catalog/config). Returns JSON `Data`.
    public func webData(_ request: WebDataRequest) async throws -> Data {
        guard let webDataClosure else {
            throw OpenAICompatibleError.notFound("Web Experience data endpoints are not available in this process.")
        }
        return try await webDataClosure(request)
    }

    public func chatCompletions(_ request: OpenAIChatCompletionsRequest) async throws -> OpenAIChatCompletionsResponse {
        if request.stream == true {
            var nonStreamingRequest = request
            nonStreamingRequest.stream = false
            return try await chatCompletions(nonStreamingRequest)
        }
        try validateResponseFormat(request.responseFormat)
        let messages = try request.messages.map(externalMessage(from:))
        let external = ExternalInferenceRequest(
            model: request.model,
            messages: messages,
            generation: GenerationConfig(
                maxTokens: request.maxCompletionTokens ?? request.maxTokens ?? GenerationConfig().maxTokens,
                temperature: request.temperature ?? GenerationConfig().temperature,
                topP: request.topP,
                topK: request.topK,
                minP: request.minP,
                repetitionPenalty: request.repetitionPenalty,
                seed: request.seed,
                enableThinking: request.enableThinking,
                thinkingBudget: request.thinkingBudget,
                thinkingStartToken: request.thinkingStartToken,
                thinkingEndToken: request.thinkingEndToken,
                kvBits: request.kvBits,
                kvQuantScheme: request.kvQuantScheme,
                kvGroupSize: request.kvGroupSize,
                quantizedKVStart: request.quantizedKVStart,
                stop: request.stop?.values
            ),
            responseFormat: eshResponseFormat(from: request.responseFormat)
        )
        let response = try await inferClosure(external)
        return OpenAIChatCompletionsResponse(
            id: identifier(prefix: "chatcmpl"),
            object: "chat.completion",
            created: unixTimestamp(),
            model: response.modelID,
            choices: [
                .init(
                    index: 0,
                    message: .init(role: "assistant", content: response.outputText),
                    finishReason: "stop"
                )
            ]
        )
    }

    public func chatCompletionsStream(_ request: OpenAIChatCompletionsRequest) async throws -> Data {
        var nonStreamingRequest = request
        nonStreamingRequest.stream = false
        let response = try await chatCompletions(nonStreamingRequest)
        let streamID = response.id
        let created = response.created
        let model = response.model
        let text = response.choices.first?.message.content ?? ""
        let chunks = streamingTextChunks(text)
        var events = Data()

        events.appendSSE(
            try encodedStreamPayload(
                OpenAIChatCompletionsStreamResponse(
                    id: streamID,
                    object: "chat.completion.chunk",
                    created: created,
                    model: model,
                    choices: [
                        .init(index: 0, delta: .init(role: "assistant", content: ""), finishReason: nil)
                    ]
                )
            )
        )

        for chunk in chunks {
            events.appendSSE(
                try encodedStreamPayload(
                    OpenAIChatCompletionsStreamResponse(
                        id: streamID,
                        object: "chat.completion.chunk",
                        created: created,
                        model: model,
                        choices: [
                            .init(index: 0, delta: .init(role: nil, content: chunk), finishReason: nil)
                        ]
                    )
                )
            )
        }

        events.appendSSE(
            try encodedStreamPayload(
                OpenAIChatCompletionsStreamResponse(
                    id: streamID,
                    object: "chat.completion.chunk",
                    created: created,
                    model: model,
                    choices: [
                        .init(index: 0, delta: .init(role: nil, content: nil), finishReason: "stop")
                    ]
                )
            )
        )
        events.append(Data("data: [DONE]\n\n".utf8))
        return events
    }

    /// A real incremental SSE provider for streaming chat completions: emits per-token deltas as the
    /// runtime produces them. Returns nil when no streaming inference is wired (caller falls back to
    /// the buffered `chatCompletionsStream`).
    public func chatCompletionsStreamProvider(
        _ request: OpenAIChatCompletionsRequest
    ) -> (@Sendable (@escaping @Sendable (Data) -> Void) async -> Void)? {
        guard let streamClosure else { return nil }
        let streamID = identifier(prefix: "chatcmpl")
        let created = unixTimestamp()
        let model = request.model ?? "esh"
        return { write in
            func emit(_ delta: OpenAIChatCompletionsStreamResponse.Delta, finish: String?) {
                let payload = OpenAIChatCompletionsStreamResponse(
                    id: streamID, object: "chat.completion.chunk", created: created, model: model,
                    choices: [.init(index: 0, delta: delta, finishReason: finish)])
                if let s = try? self.encodedStreamPayload(payload) {
                    var d = Data(); d.appendSSE(s); write(d)
                }
            }
            emit(.init(role: "assistant", content: ""), finish: nil)
            do {
                let messages = try request.messages.map(self.externalMessage(from:))
                let external = ExternalInferenceRequest(
                    model: request.model, messages: messages,
                    generation: GenerationConfig(
                        maxTokens: request.maxCompletionTokens ?? request.maxTokens ?? GenerationConfig().maxTokens,
                        temperature: request.temperature ?? GenerationConfig().temperature,
                        topP: request.topP, topK: request.topK, minP: request.minP,
                        repetitionPenalty: request.repetitionPenalty, seed: request.seed,
                        enableThinking: request.enableThinking, thinkingBudget: request.thinkingBudget,
                        thinkingStartToken: request.thinkingStartToken, thinkingEndToken: request.thinkingEndToken,
                        kvBits: request.kvBits, kvQuantScheme: request.kvQuantScheme,
                        kvGroupSize: request.kvGroupSize, quantizedKVStart: request.quantizedKVStart,
                        stop: request.stop?.values),
                    responseFormat: eshResponseFormat(from: request.responseFormat))
                let execSentinel = "\u{01}ESHEXEC:"
                for try await chunk in streamClosure(external) where chunk.isEmpty == false {
                    if chunk.hasPrefix(execSentinel) {
                        // Final per-response execution telemetry — pass through as an esh_execution SSE frame.
                        let json = String(chunk.dropFirst(execSentinel.count))
                        write(Data("data: {\"esh_execution\":\(json)}\n\n".utf8))
                    } else {
                        emit(.init(role: nil, content: chunk), finish: nil)
                    }
                }
                emit(.init(role: nil, content: nil), finish: "stop")
            } catch {
                emit(.init(role: nil, content: "\n[error] \(error.localizedDescription)"), finish: "stop")
            }
            var done = Data(); done.append(Data("data: [DONE]\n\n".utf8)); write(done)
        }
    }

    public func responses(_ request: OpenAIResponsesRequest) async throws -> OpenAIResponsesResponse {
        if request.stream == true {
            var nonStreamingRequest = request
            nonStreamingRequest.stream = false
            return try await responses(nonStreamingRequest)
        }
        try validateResponseFormat(request.responseFormat)

        var messages: [ExternalInferenceMessage] = []
        if let instructions = request.instructions?.trimmingCharacters(in: .whitespacesAndNewlines), !instructions.isEmpty {
            messages.append(.init(role: .system, text: instructions))
        }
        switch request.input {
        case .text(let text):
            messages.append(.init(role: .user, text: text))
        case .messages(let inputMessages):
            messages.append(contentsOf: try inputMessages.map(externalMessage(from:)))
        }

        let external = ExternalInferenceRequest(
            model: request.model,
            messages: messages,
            generation: GenerationConfig(
                maxTokens: request.maxOutputTokens ?? GenerationConfig().maxTokens,
                temperature: request.temperature ?? GenerationConfig().temperature,
                topP: request.topP,
                topK: request.topK,
                minP: request.minP,
                repetitionPenalty: request.repetitionPenalty,
                seed: request.seed,
                enableThinking: request.enableThinking,
                thinkingBudget: request.thinkingBudget,
                thinkingStartToken: request.thinkingStartToken,
                thinkingEndToken: request.thinkingEndToken,
                kvBits: request.kvBits,
                kvQuantScheme: request.kvQuantScheme,
                kvGroupSize: request.kvGroupSize,
                quantizedKVStart: request.quantizedKVStart,
                stop: request.stop?.values
            ),
            responseFormat: eshResponseFormat(from: request.responseFormat)
        )
        let response = try await inferClosure(external)
        let responseID = identifier(prefix: "resp")
        return OpenAIResponsesResponse(
            id: responseID,
            object: "response",
            createdAt: unixTimestamp(),
            model: response.modelID,
            output: [
                .init(
                    id: "\(responseID)_msg_0",
                    type: "message",
                    role: "assistant",
                    content: [
                        .init(type: "output_text", text: response.outputText, annotations: [])
                    ]
                )
            ],
            outputText: response.outputText
        )
    }

    public func responsesStream(_ request: OpenAIResponsesRequest) async throws -> Data {
        var nonStreamingRequest = request
        nonStreamingRequest.stream = false
        let response = try await responses(nonStreamingRequest)
        let text = response.outputText
        var events = Data()
        var sequence = 0
        let item = response.output.first

        func appendEvent(_ name: String, _ event: OpenAIResponsesStreamEvent) throws {
            events.append(Data("event: \(name)\n".utf8))
            events.appendSSE(try encodedStreamPayload(event))
        }

        try appendEvent(
            "response.created",
            .init(
                type: "response.created",
                sequenceNumber: sequence,
                itemID: nil,
                outputIndex: nil,
                contentIndex: nil,
                delta: nil,
                text: nil,
                item: nil,
                part: nil,
                response: response
            )
        )
        sequence += 1

        if let item {
            try appendEvent(
                "response.output_item.added",
                .init(
                    type: "response.output_item.added",
                    sequenceNumber: sequence,
                    itemID: item.id,
                    outputIndex: 0,
                    contentIndex: nil,
                    delta: nil,
                    text: nil,
                    item: responseOutputItemJSON(id: item.id, role: item.role, text: "", status: "in_progress"),
                    part: nil,
                    response: nil
                )
            )
            sequence += 1

            try appendEvent(
                "response.content_part.added",
                .init(
                    type: "response.content_part.added",
                    sequenceNumber: sequence,
                    itemID: item.id,
                    outputIndex: 0,
                    contentIndex: 0,
                    delta: nil,
                    text: nil,
                    item: nil,
                    part: outputTextPartJSON(text: ""),
                    response: nil
                )
            )
            sequence += 1
        }

        for chunk in streamingTextChunks(text) {
            try appendEvent(
                "response.output_text.delta",
                .init(
                    type: "response.output_text.delta",
                    sequenceNumber: sequence,
                    itemID: response.output.first?.id,
                    outputIndex: 0,
                    contentIndex: 0,
                    delta: chunk,
                    text: nil,
                    item: nil,
                    part: nil,
                    response: nil
                )
            )
            sequence += 1
        }

        try appendEvent(
            "response.output_text.done",
            .init(
                type: "response.output_text.done",
                sequenceNumber: sequence,
                itemID: response.output.first?.id,
                outputIndex: 0,
                contentIndex: 0,
                delta: nil,
                text: text,
                item: nil,
                part: nil,
                response: nil
            )
        )
        sequence += 1
        if let item {
            try appendEvent(
                "response.content_part.done",
                .init(
                    type: "response.content_part.done",
                    sequenceNumber: sequence,
                    itemID: item.id,
                    outputIndex: 0,
                    contentIndex: 0,
                    delta: nil,
                    text: nil,
                    item: nil,
                    part: outputTextPartJSON(text: text),
                    response: nil
                )
            )
            sequence += 1

            try appendEvent(
                "response.output_item.done",
                .init(
                    type: "response.output_item.done",
                    sequenceNumber: sequence,
                    itemID: item.id,
                    outputIndex: 0,
                    contentIndex: nil,
                    delta: nil,
                    text: nil,
                    item: responseOutputItemJSON(id: item.id, role: item.role, text: text, status: "completed"),
                    part: nil,
                    response: nil
                )
            )
            sequence += 1
        }
        try appendEvent(
            "response.completed",
            .init(
                type: "response.completed",
                sequenceNumber: sequence,
                itemID: nil,
                outputIndex: nil,
                contentIndex: nil,
                delta: nil,
                text: nil,
                item: nil,
                part: nil,
                response: response
            )
        )
        events.append(Data("data: [DONE]\n\n".utf8))
        return events
    }

    public func models() throws -> OpenAIModelsResponse {
        let textModels = try installedModelsClosure()
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
            .map {
                OpenAIModelsResponse.Model(
                    id: $0.id,
                    object: "model",
                    created: 0,
                    ownedBy: "esh"
                )
            }
        return OpenAIModelsResponse(object: "list", data: textModels)
    }

    public func audioModels() throws -> OpenAIAudioModelsResponse {
        let models = try audioModelsClosure()
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
        return OpenAIAudioModelsResponse(object: "list", data: models)
    }

    public func audioSpeech(_ request: OpenAIAudioSpeechRequest) async throws -> OpenAIAudioSpeechResponse {
        let trimmedInput = request.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedInput.isEmpty == false else {
            throw OpenAICompatibleError.invalidRequest("Audio input must not be empty.")
        }

        if let responseFormat = request.responseFormat?.trimmingCharacters(in: .whitespacesAndNewlines),
           responseFormat.isEmpty == false,
           responseFormat.localizedCaseInsensitiveCompare("wav") != .orderedSame {
            throw OpenAICompatibleError.unsupported("Only wav response_format is supported.")
        }

        var normalized = request
        normalized.input = trimmedInput
        normalized.responseFormat = "wav"
        return try await speechClosure(normalized)
    }

    public func audioTranscription(_ request: OpenAIAudioTranscriptionRequest) async throws -> OpenAIAudioTranscriptionResponse {
        guard let transcribeClosure else {
            throw OpenAICompatibleError.unsupported(
                "Speech-to-text is not available. Install a transcription model (e.g. `esh model install mlx-community/parakeet-tdt-0.6b-v2`) and set it with `esh config set-speech --stt <model>`."
            )
        }
        guard request.audio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw OpenAICompatibleError.invalidRequest("Audio payload must not be empty.")
        }
        return try await transcribeClosure(request)
    }

    public func ollamaTags() throws -> OllamaTagsResponse {
        let models = try installedModelsClosure()
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
            .map { model in
                OllamaTagsResponse.Model(
                    name: model.id,
                    model: model.id,
                    modifiedAt: "1970-01-01T00:00:00Z",
                    size: 0,
                    digest: model.id,
                    details: .init(
                        format: model.backend.rawValue,
                        family: "esh",
                        parameterSize: "unknown",
                        quantizationLevel: model.variant ?? "unknown"
                    )
                )
            }
        return OllamaTagsResponse(models: models)
    }

    public func tools() -> OpenAIToolsResponse {
        OpenAIToolsResponse(object: "list", data: [], supportsRequestTools: true)
    }

    private func externalMessage(from message: OpenAIInputMessage) throws -> ExternalInferenceMessage {
        let normalizedRole = message.role.lowercased()
        let role: Message.Role
        if normalizedRole == "developer" {
            role = .system
        } else if let parsed = Message.Role(rawValue: normalizedRole) {
            role = parsed
        } else {
            throw OpenAICompatibleError.invalidRequest("Unsupported message role: \(message.role)")
        }
        guard role != .tool else {
            throw OpenAICompatibleError.unsupported("Tool messages are not supported yet.")
        }
        return ExternalInferenceMessage(role: role, text: try message.content.flattenedText())
    }

    private func validateResponseFormat(_ responseFormat: OpenAIResponseFormat?) throws {
        guard let responseFormat else { return }
        // response_format is resolved per-backend at inference time (CapabilityResolver): GGUF enforces
        // json_schema/json natively via constrained decoding through llama-server, while a backend with
        // no native constrained decoding honestly rejects a strict request (ExternalInferenceService
        // throws "Strict structured output rejected") or approximates a non-strict one. So there is no
        // blanket gate here — only a structural check on the declared type.
        let type = responseFormat.type.lowercased()
        let known = ["text", "json_object", "json_schema"]
        guard known.contains(type) else {
            throw OpenAICompatibleError.invalidRequest("Unsupported response_format type: \(responseFormat.type)")
        }
    }

    /// Convert an OpenAI `response_format` into the canonical `EshResponseFormat` so the per-backend
    /// CapabilityResolver can enforce it (GGUF constrains natively; other backends reject strict or
    /// approximate non-strict). Without this the field was parsed but never reached the resolver.
    private func eshResponseFormat(from responseFormat: OpenAIResponseFormat?) -> EshResponseFormat? {
        guard let responseFormat else { return nil }
        switch responseFormat.type.lowercased() {
        case "text":
            return EshResponseFormat(kind: .text)
        case "json_object":
            return EshResponseFormat(kind: .json)
        case "json_schema":
            var schemaString: String?
            var strict = false
            if case let .object(obj)? = responseFormat.jsonSchema {
                if case let .bool(value)? = obj["strict"] { strict = value }
                if let schemaValue = obj["schema"],
                   let data = try? JSONEncoder().encode(schemaValue) {
                    schemaString = String(decoding: data, as: UTF8.self)
                }
            }
            return EshResponseFormat(kind: .jsonSchema, schema: schemaString, strict: strict)
        default:
            return nil
        }
    }

    private func unixTimestamp() -> Int {
        Int(Date().timeIntervalSince1970)
    }

    private func identifier(prefix: String) -> String {
        "\(prefix)_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }

    private func streamingTextChunks(_ text: String) -> [String] {
        guard text.isEmpty == false else { return [] }
        var chunks: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if current.count >= 24 || character.isWhitespace {
                chunks.append(current)
                current = ""
            }
        }
        if current.isEmpty == false {
            chunks.append(current)
        }
        return chunks
    }

    private func encodedStreamPayload<T: Encodable>(_ payload: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw OpenAICompatibleError.invalidRequest("Could not encode streaming payload.")
        }
        return text
    }

    private func responseOutputItemJSON(id: String, role: String, text: String, status: String) -> JSONValue {
        .object([
            "id": .string(id),
            "type": .string("message"),
            "role": .string(role),
            "status": .string(status),
            "content": .array([outputTextPartJSON(text: text)])
        ])
    }

    private func outputTextPartJSON(text: String) -> JSONValue {
        .object([
            "type": .string("output_text"),
            "text": .string(text),
            "annotations": .array([])
        ])
    }
}

private extension Data {
    mutating func appendSSE(_ payload: String) {
        append(Data("data: \(payload)\n\n".utf8))
    }
}
