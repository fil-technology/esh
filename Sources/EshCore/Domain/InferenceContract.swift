import Foundation

/// Requested output format for a generation. Part of esh's native inference contract (M8); the
/// OpenAI/Anthropic adapters map their `response_format` onto this.
public struct EshResponseFormat: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case text
        case json
        case jsonSchema = "json_schema"
        case grammar
    }

    public var kind: Kind
    /// JSON Schema text (for `.jsonSchema`).
    public var schema: String?
    /// Grammar text, e.g. GBNF (for `.grammar`).
    public var grammar: String?
    /// When true, the caller requires a NATIVE constraint. If the backend cannot enforce it
    /// natively, the request is rejected rather than approximated via a prompt instruction.
    public var strict: Bool

    public init(kind: Kind, schema: String? = nil, grammar: String? = nil, strict: Bool = false) {
        self.kind = kind
        self.schema = schema
        self.grammar = grammar
        self.strict = strict
    }

    public static let text = EshResponseFormat(kind: .text)
    public static let json = EshResponseFormat(kind: .json)
}

/// How a requested option was actually handled. The contract NEVER silently pretends an
/// unsupported option was honored — every consequential option resolves to one of these.
public enum OptionResolution: String, Codable, Sendable {
    case applied       // honored natively, as requested
    case transformed   // mapped to a native equivalent (e.g. a renamed parameter)
    case approximated  // simulated via a non-native mechanism (e.g. JSON via a prompt instruction)
    case ignored       // ignored by explicit policy / no effect on this backend
    case rejected      // requested but cannot be satisfied (unsupported, or strict-mode)
}

public struct ResolvedOption: Codable, Hashable, Sendable {
    public var name: String
    public var resolution: OptionResolution
    public var detail: String?

    public init(name: String, resolution: OptionResolution, detail: String? = nil) {
        self.name = name
        self.resolution = resolution
        self.detail = detail
    }
}

/// The set of capability-resolution decisions for a request. Attached to the inference response so
/// callers (Ashex, the CLI, compatibility adapters) see exactly what was applied/transformed/
/// ignored/rejected.
public struct CapabilityResolution: Codable, Hashable, Sendable {
    public var options: [ResolvedOption]

    public init(options: [ResolvedOption] = []) {
        self.options = options
    }

    public var isEmpty: Bool { options.isEmpty }
    public func first(named name: String) -> ResolvedOption? { options.first { $0.name == name } }
    public var hasRejections: Bool { options.contains { $0.resolution == .rejected } }
}
