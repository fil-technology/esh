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
    public var maxTokens: Int?
    public var maxCompletionTokens: Int?
    public var stream: Bool?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
        case stream
    }
}

public struct OpenAIResponsesRequest: Codable, Hashable, Sendable {
    public var model: String?
    public var input: OpenAIResponsesInput
    public var instructions: String?
    public var temperature: Double?
    public var maxOutputTokens: Int?
    public var stream: Bool?

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case instructions
        case temperature
        case maxOutputTokens = "max_output_tokens"
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
            guard texts.isEmpty == false else {
                throw OpenAICompatibleError.unsupported("Only text content parts are supported in v1.")
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
        case "text", "input_text":
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

public struct OpenAIModelsResponse: Codable, Hashable, Sendable {
    public var object: String
    public var data: [Model]

    public struct Model: Codable, Hashable, Sendable {
        public var id: String
        public var object: String
        public var created: Int
        public var ownedBy: String
        public var modality: String?
        public var capabilities: [String]?

        enum CodingKeys: String, CodingKey {
            case id
            case object
            case created
            case ownedBy = "owned_by"
            case modality
            case capabilities
        }
    }
}

public struct OpenAIAudioModelsResponse: Codable, Hashable, Sendable {
    public var object: String
    public var data: [OpenAIAudioModel]
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

    public init(
        infer: @escaping @Sendable (ExternalInferenceRequest) async throws -> ExternalInferenceResponse,
        installedModels: @escaping @Sendable () throws -> [ExternalInstalledModelCapability],
        audioModels: @escaping @Sendable () throws -> [OpenAIAudioModel] = { [] }
    ) {
        self.inferClosure = infer
        self.installedModelsClosure = installedModels
        self.audioModelsClosure = audioModels
    }

    public init(
        modelStore: ModelStore,
        sessionStore: SessionStore,
        cacheStore: CacheStore,
        toolVersion: String? = nil,
        registry: InferenceBackendRegistry = .init(),
        workspaceRootURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        audioModels: @escaping @Sendable () throws -> [OpenAIAudioModel] = { [] }
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
            audioModels: audioModels
        )
    }

    public func chatCompletions(_ request: OpenAIChatCompletionsRequest) async throws -> OpenAIChatCompletionsResponse {
        if request.stream == true {
            throw OpenAICompatibleError.unsupported("`stream` is not supported yet.")
        }
        let messages = try request.messages.map(externalMessage(from:))
        let external = ExternalInferenceRequest(
            model: request.model,
            messages: messages,
            generation: GenerationConfig(
                maxTokens: request.maxCompletionTokens ?? request.maxTokens ?? GenerationConfig().maxTokens,
                temperature: request.temperature ?? GenerationConfig().temperature
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

    public func responses(_ request: OpenAIResponsesRequest) async throws -> OpenAIResponsesResponse {
        if request.stream == true {
            throw OpenAICompatibleError.unsupported("`stream` is not supported yet.")
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
                temperature: request.temperature ?? GenerationConfig().temperature
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

    public func models() throws -> OpenAIModelsResponse {
        let textModels = try installedModelsClosure()
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
            .map {
                OpenAIModelsResponse.Model(
                    id: $0.id,
                    object: "model",
                    created: 0,
                    ownedBy: "esh",
                    modality: "text",
                    capabilities: ["chat", "responses"]
                )
            }
        let audioModels = try audioModelsClosure()
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
            .map {
                OpenAIModelsResponse.Model(
                    id: $0.id,
                    object: $0.object,
                    created: $0.created,
                    ownedBy: $0.ownedBy,
                    modality: "audio",
                    capabilities: $0.capabilities
                )
            }
        return OpenAIModelsResponse(object: "list", data: textModels + audioModels)
    }

    public func audioModels() throws -> OpenAIAudioModelsResponse {
        let models = try audioModelsClosure()
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
        return OpenAIAudioModelsResponse(object: "list", data: models)
    }

    private func externalMessage(from message: OpenAIInputMessage) throws -> ExternalInferenceMessage {
        guard let role = Message.Role(rawValue: message.role) else {
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
}
