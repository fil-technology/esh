import Foundation

public struct AnthropicMessagesRequest: Codable, Hashable, Sendable {
    public var model: String?
    public var system: AnthropicContentContainer?
    public var messages: [AnthropicInputMessage]
    public var maxTokens: Int
    public var temperature: Double?
    public var topP: Double?
    public var topK: Int?
    public var stream: Bool?

    enum CodingKeys: String, CodingKey {
        case model
        case system
        case messages
        case maxTokens = "max_tokens"
        case temperature
        case topP = "top_p"
        case topK = "top_k"
        case stream
    }

    public init(
        model: String? = nil,
        system: AnthropicContentContainer? = nil,
        messages: [AnthropicInputMessage],
        maxTokens: Int,
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        stream: Bool? = nil
    ) {
        self.model = model
        self.system = system
        self.messages = messages
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.stream = stream
    }
}

public struct AnthropicInputMessage: Codable, Hashable, Sendable {
    public var role: String
    public var content: AnthropicContentContainer

    public init(role: String, content: AnthropicContentContainer) {
        self.role = role
        self.content = content
    }
}

public enum AnthropicContentContainer: Codable, Hashable, Sendable {
    case text(String)
    case parts([AnthropicContentPart])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
            return
        }
        self = .parts(try container.decode([AnthropicContentPart].self))
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
                guard part.type == "text" else { return nil }
                return part.text
            }
            return texts.joined()
        }
    }
}

public struct AnthropicContentPart: Codable, Hashable, Sendable {
    public var type: String
    public var text: String?

    public init(type: String, text: String? = nil) {
        self.type = type
        self.text = text
    }
}

public struct AnthropicMessageResponse: Codable, Hashable, Sendable {
    public var id: String
    public var type: String
    public var role: String
    public var content: [Content]
    public var model: String
    public var stopReason: String
    public var stopSequence: String?
    public var usage: Usage

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case role
        case content
        case model
        case stopReason = "stop_reason"
        case stopSequence = "stop_sequence"
        case usage
    }

    public struct Content: Codable, Hashable, Sendable {
        public var type: String
        public var text: String
    }

    public struct Usage: Codable, Hashable, Sendable {
        public var inputTokens: Int
        public var outputTokens: Int

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }
}

public struct AnthropicModelsResponse: Codable, Hashable, Sendable {
    public var data: [Model]

    public struct Model: Codable, Hashable, Sendable {
        public var id: String
        public var type: String
        public var displayName: String

        enum CodingKeys: String, CodingKey {
            case id
            case type
            case displayName = "display_name"
        }
    }
}

public struct AnthropicErrorResponse: Codable, Hashable, Sendable {
    public var type: String
    public var error: ErrorBody

    public struct ErrorBody: Codable, Hashable, Sendable {
        public var type: String
        public var message: String
    }
}

public struct AnthropicCompatibleService: Sendable {
    private let inferClosure: @Sendable (ExternalInferenceRequest) async throws -> ExternalInferenceResponse
    private let installedModelsClosure: @Sendable () throws -> [ExternalInstalledModelCapability]

    public init(
        infer: @escaping @Sendable (ExternalInferenceRequest) async throws -> ExternalInferenceResponse,
        installedModels: @escaping @Sendable () throws -> [ExternalInstalledModelCapability]
    ) {
        self.inferClosure = infer
        self.installedModelsClosure = installedModels
    }

    public init(
        modelStore: ModelStore,
        sessionStore: SessionStore,
        cacheStore: CacheStore,
        toolVersion: String? = nil,
        registry: InferenceBackendRegistry = .init(),
        workspaceRootURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
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
            }
        )
    }

    public func messages(_ request: AnthropicMessagesRequest) async throws -> AnthropicMessageResponse {
        if request.stream == true {
            var nonStreaming = request
            nonStreaming.stream = false
            return try await messages(nonStreaming)
        }

        let external = try externalRequest(from: request)
        let response = try await inferClosure(external)
        return messageResponse(from: response)
    }

    public func messagesStream(_ request: AnthropicMessagesRequest) async throws -> Data {
        var nonStreaming = request
        nonStreaming.stream = false
        let response = try await messages(nonStreaming)
        let text = response.content.first?.text ?? ""
        let chunks = streamingTextChunks(text)
        let messageID = response.id
        var payload = Data()

        try payload.appendAnthropicEvent(
            name: "message_start",
            body: [
                "type": "message_start",
                "message": [
                    "id": messageID,
                    "type": "message",
                    "role": "assistant",
                    "content": [],
                    "model": response.model,
                    "stop_reason": NSNull(),
                    "stop_sequence": NSNull(),
                    "usage": [
                        "input_tokens": response.usage.inputTokens,
                        "output_tokens": 0
                    ]
                ]
            ]
        )
        try payload.appendAnthropicEvent(
            name: "content_block_start",
            body: [
                "type": "content_block_start",
                "index": 0,
                "content_block": [
                    "type": "text",
                    "text": ""
                ]
            ]
        )
        for chunk in chunks {
            try payload.appendAnthropicEvent(
                name: "content_block_delta",
                body: [
                    "type": "content_block_delta",
                    "index": 0,
                    "delta": [
                        "type": "text_delta",
                        "text": chunk
                    ]
                ]
            )
        }
        try payload.appendAnthropicEvent(
            name: "content_block_stop",
            body: [
                "type": "content_block_stop",
                "index": 0
            ]
        )
        try payload.appendAnthropicEvent(
            name: "message_delta",
            body: {
                let delta: [String: Any] = [
                    "stop_reason": response.stopReason,
                    "stop_sequence": response.stopSequence ?? NSNull()
                ]
                return [
                    "type": "message_delta",
                    "delta": delta,
                    "usage": [
                        "output_tokens": response.usage.outputTokens
                    ]
                ]
            }()
        )
        try payload.appendAnthropicEvent(
            name: "message_stop",
            body: [
                "type": "message_stop"
            ]
        )
        return payload
    }

    public func models() throws -> AnthropicModelsResponse {
        let models = try installedModelsClosure()
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
            .map {
                AnthropicModelsResponse.Model(id: $0.id, type: "model", displayName: $0.displayName)
            }
        return AnthropicModelsResponse(data: models)
    }

    private func externalRequest(from request: AnthropicMessagesRequest) throws -> ExternalInferenceRequest {
        var messages: [ExternalInferenceMessage] = []
        if let system = request.system {
            let systemText = try system.flattenedText()
            if systemText.isEmpty == false {
                messages.append(.init(role: .system, text: systemText))
            }
        }
        messages.append(contentsOf: try request.messages.map(externalMessage(from:)))
        return ExternalInferenceRequest(
            model: request.model,
            messages: messages,
            generation: GenerationConfig(
                maxTokens: request.maxTokens,
                temperature: request.temperature ?? GenerationConfig().temperature,
                topP: request.topP,
                topK: request.topK
            )
        )
    }

    private func externalMessage(from message: AnthropicInputMessage) throws -> ExternalInferenceMessage {
        guard let role = Message.Role(rawValue: message.role) else {
            throw OpenAICompatibleError.invalidRequest("Unsupported message role: \(message.role)")
        }
        guard role != .tool else {
            throw OpenAICompatibleError.unsupported("Tool messages are not supported yet.")
        }
        return .init(role: role, text: try message.content.flattenedText())
    }

    private func messageResponse(from response: ExternalInferenceResponse) -> AnthropicMessageResponse {
        AnthropicMessageResponse(
            id: identifier(prefix: "msg"),
            type: "message",
            role: "assistant",
            content: [
                .init(type: "text", text: response.outputText)
            ],
            model: response.modelID,
            stopReason: "end_turn",
            stopSequence: nil,
            usage: .init(
                inputTokens: response.metrics.contextTokens ?? 0,
                outputTokens: max(response.outputText.count / 4, 1)
            )
        )
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
}

private extension Data {
    mutating func appendAnthropicEvent(name: String, body: [String: Any]) throws {
        let json = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        guard let text = String(data: json, encoding: .utf8) else {
            throw OpenAICompatibleError.invalidRequest("Could not encode Anthropic streaming payload.")
        }
        append(Data("event: \(name)\n".utf8))
        append(Data("data: \(text)\n\n".utf8))
    }
}
