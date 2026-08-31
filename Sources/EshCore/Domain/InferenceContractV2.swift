import Foundation

// M8 canonical inference contract — tools and usage. These are backend-agnostic representations;
// compatibility adapters (OpenAI/Anthropic/Ollama) map onto them, not the other way round.

/// A tool/function the model may call, with a JSON-schema parameter spec.
public struct EshToolDefinition: Codable, Hashable, Sendable {
    public var name: String
    public var description: String?
    /// JSON Schema (as text) for the tool's parameters.
    public var parametersSchemaJSON: String?

    public init(name: String, description: String? = nil, parametersSchemaJSON: String? = nil) {
        self.name = name
        self.description = description
        self.parametersSchemaJSON = parametersSchemaJSON
    }
}

/// How the model should choose among tools.
public struct EshToolChoice: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, Sendable {
        case auto        // model decides
        case none        // do not call tools
        case required    // must call some tool
        case specific    // must call `toolName`
    }
    public var mode: Mode
    public var toolName: String?

    public init(mode: Mode, toolName: String? = nil) {
        self.mode = mode
        self.toolName = toolName
    }
    public static let auto = EshToolChoice(mode: .auto)
    public static let none = EshToolChoice(mode: .none)
    public static let required = EshToolChoice(mode: .required)
}

/// A tool call the model produced.
public struct EshToolCall: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var argumentsJSON: String
    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

/// Normalized token/usage accounting. Every field is optional and populated ONLY when the backend
/// actually reports it — never fabricated. `available` lists which counters were measurable.
public struct EshUsage: Codable, Hashable, Sendable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var reasoningTokens: Int?
    public var cachedInputTokens: Int?
    public var totalTokens: Int?
    public var contextUsed: Int?
    public var contextLimit: Int?
    /// Local execution: monetary API cost is 0. Compute/resource usage is separate (see metrics).
    public var monetaryCostUSD: Double
    public var costProvenance: String

    public init(
        inputTokens: Int? = nil, outputTokens: Int? = nil, reasoningTokens: Int? = nil,
        cachedInputTokens: Int? = nil, totalTokens: Int? = nil,
        contextUsed: Int? = nil, contextLimit: Int? = nil,
        monetaryCostUSD: Double = 0, costProvenance: String = "local (on-device); no API cost"
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cachedInputTokens = cachedInputTokens
        self.totalTokens = totalTokens
        self.contextUsed = contextUsed
        self.contextLimit = contextLimit
        self.monetaryCostUSD = monetaryCostUSD
        self.costProvenance = costProvenance
    }

    /// Which counters were actually measurable (provenance, not fabrication).
    public var available: [String] {
        var keys: [String] = []
        if inputTokens != nil { keys.append("inputTokens") }
        if outputTokens != nil { keys.append("outputTokens") }
        if reasoningTokens != nil { keys.append("reasoningTokens") }
        if cachedInputTokens != nil { keys.append("cachedInputTokens") }
        if totalTokens != nil { keys.append("totalTokens") }
        if contextUsed != nil { keys.append("contextUsed") }
        return keys
    }
}
