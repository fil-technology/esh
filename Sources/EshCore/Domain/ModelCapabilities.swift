import Foundation

public enum ModelTask: String, Codable, Hashable, Sendable, CaseIterable {
    case text
    case audio
    case vision
    case embedding
    case reranker
    case tool
    case multimodal
}

public enum ModelModality: String, Codable, Hashable, Sendable, CaseIterable {
    case text
    case audio
    case image
    case video
    case embedding
    case json
    case toolCall
}

public struct ModelCapabilities: Codable, Hashable, Sendable {
    public var text: TextCapabilities?
    public var audio: AudioCapabilities?
    public var vision: VisionCapabilities?
    public var embedding: EmbeddingCapabilities?
    public var reranker: RerankerCapabilities?
    public var tool: ToolCapabilities?

    public init(
        text: TextCapabilities? = nil,
        audio: AudioCapabilities? = nil,
        vision: VisionCapabilities? = nil,
        embedding: EmbeddingCapabilities? = nil,
        reranker: RerankerCapabilities? = nil,
        tool: ToolCapabilities? = nil
    ) {
        self.text = text
        self.audio = audio
        self.vision = vision
        self.embedding = embedding
        self.reranker = reranker
        self.tool = tool
    }

    public static let textGeneration = ModelCapabilities(
        text: TextCapabilities(
            supportsChat: true,
            supportsCompletion: true,
            supportsSummarization: true,
            supportsReasoning: false,
            supportsStreaming: true,
            supportsStructuredOutput: false
        )
    )

    public func supports(capability: ModelCapabilityFilter) -> Bool {
        switch capability {
        case .chat:
            return text?.supportsChat == true
        case .completion:
            return text?.supportsCompletion == true
        case .summarization:
            return text?.supportsSummarization == true
        case .reasoning:
            return text?.supportsReasoning == true
        case .structuredOutput:
            return text?.supportsStructuredOutput == true
        case .tts:
            return audio?.supportsTTS == true
        case .stt:
            return audio?.supportsSTT == true
        case .sts:
            return audio?.supportsSTS == true
        case .timestamps:
            return audio?.supportsTimestamps == true
        case .imageUnderstanding:
            return vision?.supportsImageUnderstanding == true
        case .ocr:
            return vision?.supportsOCR == true
        case .embedding:
            return embedding?.supportsEmbedding == true
        case .rerank:
            return reranker?.supportsReranking == true
        case .toolCalling:
            return tool?.supportsToolCalling == true
        case .jsonPlanning:
            return tool?.supportsJSONPlanning == true
        }
    }
}

public struct TextCapabilities: Codable, Hashable, Sendable {
    public var supportsChat: Bool
    public var supportsCompletion: Bool
    public var supportsSummarization: Bool
    public var supportsReasoning: Bool
    public var supportsStreaming: Bool
    public var supportsStructuredOutput: Bool

    public init(
        supportsChat: Bool,
        supportsCompletion: Bool,
        supportsSummarization: Bool,
        supportsReasoning: Bool,
        supportsStreaming: Bool,
        supportsStructuredOutput: Bool
    ) {
        self.supportsChat = supportsChat
        self.supportsCompletion = supportsCompletion
        self.supportsSummarization = supportsSummarization
        self.supportsReasoning = supportsReasoning
        self.supportsStreaming = supportsStreaming
        self.supportsStructuredOutput = supportsStructuredOutput
    }
}

public struct AudioCapabilities: Codable, Hashable, Sendable {
    public var supportsTTS: Bool
    public var supportsSTT: Bool
    public var supportsSTS: Bool
    public var supportsTimestamps: Bool
    public var supportsStreaming: Bool
    public var supportedOutputFormats: [String]
    public var supportedInputFormats: [String]
    public var voices: [AudioVoice]

    public init(
        supportsTTS: Bool = false,
        supportsSTT: Bool = false,
        supportsSTS: Bool = false,
        supportsTimestamps: Bool = false,
        supportsStreaming: Bool = false,
        supportedOutputFormats: [String] = [],
        supportedInputFormats: [String] = [],
        voices: [AudioVoice] = []
    ) {
        self.supportsTTS = supportsTTS
        self.supportsSTT = supportsSTT
        self.supportsSTS = supportsSTS
        self.supportsTimestamps = supportsTimestamps
        self.supportsStreaming = supportsStreaming
        self.supportedOutputFormats = supportedOutputFormats
        self.supportedInputFormats = supportedInputFormats
        self.voices = voices
    }
}

public struct AudioVoice: Codable, Hashable, Sendable {
    public var id: String
    public var displayName: String?
    public var language: String?
    public var gender: String?
    public var notes: String?

    public init(
        id: String,
        displayName: String? = nil,
        language: String? = nil,
        gender: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.language = language
        self.gender = gender
        self.notes = notes
    }
}

public struct VisionCapabilities: Codable, Hashable, Sendable {
    public var supportsImageUnderstanding: Bool
    public var supportsOCR: Bool

    public init(supportsImageUnderstanding: Bool = false, supportsOCR: Bool = false) {
        self.supportsImageUnderstanding = supportsImageUnderstanding
        self.supportsOCR = supportsOCR
    }
}

public struct EmbeddingCapabilities: Codable, Hashable, Sendable {
    public var supportsEmbedding: Bool
    public var dimensions: Int?

    public init(supportsEmbedding: Bool = false, dimensions: Int? = nil) {
        self.supportsEmbedding = supportsEmbedding
        self.dimensions = dimensions
    }
}

public struct RerankerCapabilities: Codable, Hashable, Sendable {
    public var supportsReranking: Bool

    public init(supportsReranking: Bool = false) {
        self.supportsReranking = supportsReranking
    }
}

public struct ToolCapabilities: Codable, Hashable, Sendable {
    public var supportsToolCalling: Bool
    public var supportsJSONPlanning: Bool

    public init(supportsToolCalling: Bool = false, supportsJSONPlanning: Bool = false) {
        self.supportsToolCalling = supportsToolCalling
        self.supportsJSONPlanning = supportsJSONPlanning
    }
}

public enum ModelCapabilityFilter: String, Codable, Hashable, Sendable, CaseIterable {
    case chat
    case completion
    case summarization
    case reasoning
    case structuredOutput = "structured-output"
    case tts
    case stt
    case sts
    case timestamps
    case imageUnderstanding = "image-understanding"
    case ocr
    case embedding
    case rerank
    case toolCalling = "tool-calling"
    case jsonPlanning = "json-planning"
}
