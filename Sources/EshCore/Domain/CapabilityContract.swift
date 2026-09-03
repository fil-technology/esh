import Foundation

// esh 2.1 — Universal Capability & Modality Runtime (UCMR), Stage 0.
// The additive canonical request: `inputs + capability + desiredOutput + constraints → typed result`.
// This does NOT replace Inference Contract v2 — `ExternalInferenceRequest` remains valid and adapts
// into an `ExecutionRequest` (capability == .languageGenerate). See docs/UCMR_ARCHITECTURE.md.

/// A capability identifier of the form `family.verb` (e.g. `language.generate`, `audio.transcribe`,
/// `vector.generate`). Modeled as data (a string), NOT a closed enum, so new capabilities can be added
/// by a provider + catalog metadata without changing core types. Well-known values are provided as
/// constants and map onto the existing `ModelCapabilityFilter` vocabulary.
public struct CapabilityID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public init(_ value: String) { self.rawValue = value }

    // Encode/decode as a bare JSON string ("language.generate"), not { "rawValue": ... }.
    public init(from decoder: Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// The part before the first dot (`language` in `language.generate`); the whole string if there is no dot.
    public var family: String { rawValue.split(separator: ".", maxSplits: 1).first.map(String.init) ?? rawValue }
    /// The part after the first dot (`generate` in `language.generate`); empty if there is no dot.
    public var verb: String {
        let parts = rawValue.split(separator: ".", maxSplits: 1)
        return parts.count > 1 ? String(parts[1]) : ""
    }
    public var description: String { rawValue }

    // Language
    public static let languageGenerate: CapabilityID = "language.generate"
    public static let languageReason: CapabilityID = "language.reason"
    public static let languageSummarize: CapabilityID = "language.summarize"
    public static let languageTranslate: CapabilityID = "language.translate"
    public static let languageClassify: CapabilityID = "language.classify"
    public static let languageExtract: CapabilityID = "language.extract"
    public static let languageEmbed: CapabilityID = "language.embed"
    public static let languageRerank: CapabilityID = "language.rerank"
    // Vision / image
    public static let imageUnderstand: CapabilityID = "image.understand"
    public static let imageOCR: CapabilityID = "image.ocr"
    public static let imageGenerate: CapabilityID = "image.generate"
    public static let imageEdit: CapabilityID = "image.edit"
    public static let imageSegment: CapabilityID = "image.segment"
    // Audio
    public static let audioTranscribe: CapabilityID = "audio.transcribe"
    public static let audioSynthesizeSpeech: CapabilityID = "audio.synthesizeSpeech"
    public static let audioUnderstand: CapabilityID = "audio.understand"
    // Video
    public static let videoUnderstand: CapabilityID = "video.understand"
    // Artifact / program generation
    public static let vectorGenerate: CapabilityID = "vector.generate"       // text → SVG
    public static let webArtifactGenerate: CapabilityID = "webArtifact.generate"
    public static let projectGenerate: CapabilityID = "project.generate"
}

/// One typed input to a capability request. Multiple inputs of mixed modality are legal
/// (e.g. text + image, video + question, document + instruction).
public struct CapabilityInput: Codable, Hashable, Sendable {
    public enum Payload: Codable, Hashable, Sendable {
        case text(String)
        case attachment(EshAttachment)      // image / document / audio / other (reuses the v2 contract type)
        case structured(JSONValue)
        case embedding([Float])
    }
    public var payload: Payload
    /// Optional semantic role, e.g. "prompt", "instruction", "reference", "question".
    public var role: String?

    public init(payload: Payload, role: String? = nil) {
        self.payload = payload
        self.role = role
    }

    public static func text(_ s: String, role: String? = nil) -> CapabilityInput { .init(payload: .text(s), role: role) }
    public static func attachment(_ a: EshAttachment, role: String? = nil) -> CapabilityInput { .init(payload: .attachment(a), role: role) }
}

/// The desired typed output. `modality` is coarse (text/image/audio/…); `format` is a MIME/format hint
/// (e.g. "image/svg+xml"); `schema` is an optional JSON schema for structured output. Do NOT assume text.
public struct OutputSpec: Codable, Hashable, Sendable {
    public var modality: ModelModality
    public var format: String?
    public var schema: String?

    public init(modality: ModelModality, format: String? = nil, schema: String? = nil) {
        self.modality = modality
        self.format = format
        self.schema = schema
    }

    public static let text = OutputSpec(modality: .text)
    public static let json = OutputSpec(modality: .json)
    public static let embedding = OutputSpec(modality: .embedding)
    public static let svg = OutputSpec(modality: .image, format: "image/svg+xml")
}

/// Execution constraints. Reuses the existing quality/latency vocabulary from `CapabilityRequest`.
public struct ExecutionConstraints: Codable, Hashable, Sendable {
    public var localOnly: Bool
    public var quality: CapabilityRequest.Quality?
    public var latency: CapabilityRequest.Latency?
    public var maxMemoryGB: Double?
    /// Ceiling on the privilege a provider/preview may use for this request (default: least privilege).
    public var maxPrivilege: PrivilegeLevel?

    public init(localOnly: Bool = true,
                quality: CapabilityRequest.Quality? = nil,
                latency: CapabilityRequest.Latency? = nil,
                maxMemoryGB: Double? = nil,
                maxPrivilege: PrivilegeLevel? = nil) {
        self.localOnly = localOnly
        self.quality = quality
        self.latency = latency
        self.maxMemoryGB = maxMemoryGB
        self.maxPrivilege = maxPrivilege
    }
    public static let `default` = ExecutionConstraints()
}

/// Capability-specific options, kept freeform+typed so a new capability doesn't require a new field on
/// the core request (e.g. embedding dimensions, image size/steps, SVG canvas bounds).
public struct ExecutionOptions: Codable, Hashable, Sendable {
    public var values: [String: JSONValue]
    public init(_ values: [String: JSONValue] = [:]) { self.values = values }
    public static let none = ExecutionOptions()
}

/// The additive canonical capability request.
public struct ExecutionRequest: Codable, Sendable {
    public static let currentSchemaVersion = "esh.execute.request.v1"
    public var schemaVersion: String
    public var capability: CapabilityID
    public var inputs: [CapabilityInput]
    public var output: OutputSpec
    public var constraints: ExecutionConstraints
    public var options: ExecutionOptions
    /// Optional explicit model id; nil means "let the scheduler resolve the best provider/model".
    public var model: String?

    public init(capability: CapabilityID,
                inputs: [CapabilityInput],
                output: OutputSpec,
                constraints: ExecutionConstraints = .default,
                options: ExecutionOptions = .none,
                model: String? = nil,
                schemaVersion: String = ExecutionRequest.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.capability = capability
        self.inputs = inputs
        self.output = output
        self.constraints = constraints
        self.options = options
        self.model = model
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, capability, inputs, output, constraints, options, model
    }

    // Tolerant decode so callers may omit schemaVersion and the optional-with-defaults fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(String.self, forKey: .schemaVersion) ?? ExecutionRequest.currentSchemaVersion
        self.capability = try c.decode(CapabilityID.self, forKey: .capability)
        self.inputs = try c.decode([CapabilityInput].self, forKey: .inputs)
        self.output = try c.decodeIfPresent(OutputSpec.self, forKey: .output) ?? .text
        self.constraints = try c.decodeIfPresent(ExecutionConstraints.self, forKey: .constraints) ?? .default
        self.options = try c.decodeIfPresent(ExecutionOptions.self, forKey: .options) ?? .none
        self.model = try c.decodeIfPresent(String.self, forKey: .model)
    }
}
