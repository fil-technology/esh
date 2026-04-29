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

public struct OpenAICompatibleService: Sendable {
    private let inferClosure: @Sendable (ExternalInferenceRequest) async throws -> ExternalInferenceResponse
    private let installedModelsClosure: @Sendable () throws -> [ExternalInstalledModelCapability]
    private let audioModelsClosure: @Sendable () throws -> [OpenAIAudioModel]
    private let speechClosure: @Sendable (OpenAIAudioSpeechRequest) async throws -> OpenAIAudioSpeechResponse

    public init(
        infer: @escaping @Sendable (ExternalInferenceRequest) async throws -> ExternalInferenceResponse,
        installedModels: @escaping @Sendable () throws -> [ExternalInstalledModelCapability],
        audioModels: @escaping @Sendable () throws -> [OpenAIAudioModel] = { [] },
        speech: @escaping @Sendable (OpenAIAudioSpeechRequest) async throws -> OpenAIAudioSpeechResponse = { _ in
            throw OpenAICompatibleError.unsupported("Audio speech generation is not available in this process.")
        }
    ) {
        self.inferClosure = infer
        self.installedModelsClosure = installedModels
        self.audioModelsClosure = audioModels
        self.speechClosure = speech
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
        }
    ) {
        let inference = ExternalInferenceService(
            modelStore: modelStore,
            sessionStore: sessionStore,
            cacheStore: cacheStore,
            registry: registry,
            workspaceRootURL: workspaceRootURL
        )
        let capabilities = ExternalCapabilitiesService(modelStore: modelStore)
        self.init(
            infer: { request in
                try await inference.infer(request: request)
            },
            installedModels: {
                try capabilities.describe(toolVersion: toolVersion).installedModels
            },
            audioModels: audioModels,
            speech: speech
        )
    }

    public func chatCompletions(_ request: OpenAIChatCompletionsRequest) async throws -> OpenAIChatCompletionsResponse {
        if request.stream == true {
            var nonStreamingRequest = request
            nonStreamingRequest.stream = false
            return try await chatCompletions(nonStreamingRequest)
        }
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
                seed: request.seed
            )
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

    public func responses(_ request: OpenAIResponsesRequest) async throws -> OpenAIResponsesResponse {
        if request.stream == true {
            var nonStreamingRequest = request
            nonStreamingRequest.stream = false
            return try await responses(nonStreamingRequest)
        }

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
                seed: request.seed
            )
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
