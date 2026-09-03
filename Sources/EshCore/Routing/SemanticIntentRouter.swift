import Foundation

// esh 2.1 — Tier 1 constrained semantic router (spec 86eyucfbu §4/§5). When Tier 0 is unsure (clarify), a
// routing MODEL is offered a schema generated from the REAL capability registry and asked to propose a
// typed intent — from capabilities that actually exist. Its output is validated independently (same as
// Tier 0) before anything runs. The router is pluggable (Apple Foundation Models / FunctionGemma / resident
// LLM); Router Auto picks per Mac via the routing benchmark. Confidence stays untrusted metadata.

/// One capability, described for the router, generated dynamically from the registry (so the router only
/// ever sees capabilities that currently exist with real argument schemas).
public struct CapabilitySchemaEntry: Codable, Sendable, Equatable {
    public var capability: String
    public var description: String
    public var inputModalities: [String]
    public var arguments: [String: String]   // name → type/desc (e.g. "scale": "integer 2..8")
    public init(capability: String, description: String, inputModalities: [String], arguments: [String: String]) {
        self.capability = capability; self.description = description
        self.inputModalities = inputModalities; self.arguments = arguments
    }
}

public enum CapabilitySchemaBuilder {
    /// Human-readable descriptions + arg schemas per capability (used only for capabilities the registry
    /// actually has a provider for).
    static let descriptions: [CapabilityID: (String, [String: String])] = [
        .imageUpscale: ("Increase an image's resolution", ["scale": "integer 2 or 4"]),
        .imageSegment: ("Remove an image's background (cutout)", [:]),
        .imageOCR: ("Read the text in an image", [:]),
        .imageUnderstand: ("Describe or answer a question about an image", [:]),
        .imageGenerate: ("Generate a new image from a text prompt", [:]),
        .vectorGenerate: ("Generate an SVG/vector graphic from a text prompt", [:]),
        .videoUnderstand: ("Answer a question about / summarize a video", [:]),
        .audioDiarize: ("Label who spoke when in audio (speaker clusters)", [:]),
    ]

    /// Build the schema from providers actually registered (capabilities with no provider are omitted).
    public static func build(from registry: CapabilityRegistry) -> [CapabilitySchemaEntry] {
        var seen = Set<String>()
        var out: [CapabilitySchemaEntry] = []
        for provider in registry.all {
            for cap in provider.descriptor.capabilities where !seen.contains(cap.rawValue) {
                guard let (desc, args) = descriptions[cap] else { continue }
                seen.insert(cap.rawValue)
                out.append(CapabilitySchemaEntry(capability: cap.rawValue, description: desc,
                    inputModalities: provider.descriptor.acceptedInputs.map { $0.rawValue }, arguments: args))
            }
        }
        return out.sorted { $0.capability < $1.capability }
    }
}

/// A pluggable Tier-1 router. Implementations must ONLY choose from the provided schema; esh validates.
public protocol SemanticIntentRouter: Sendable {
    var name: String { get }
    func propose(message: String, inputModalities: [ModelModality],
                 schema: [CapabilitySchemaEntry]) async -> CapabilityIntent?
}

/// Default Tier-1 router using a resident LLM constrained to emit a single JSON intent from the schema.
/// Zero extra download (uses whatever LLM is resident). Output is parsed defensively + validated by the
/// resolver; a malformed/for-unknown-capability answer is discarded (no false execution).
public struct ResidentLLMSemanticRouter: SemanticIntentRouter {
    public typealias InferFn = @Sendable (ExternalInferenceRequest) async throws -> ExternalInferenceResponse
    public let name: String
    private let infer: InferFn
    public init(name: String = "resident-llm", infer: @escaping InferFn) { self.name = name; self.infer = infer }

    public func propose(message: String, inputModalities: [ModelModality], schema: [CapabilitySchemaEntry]) async -> CapabilityIntent? {
        guard !schema.isEmpty else { return nil }
        let schemaJSON = (try? String(decoding: JSONCoding.encoder.encode(schema), as: UTF8.self)) ?? "[]"
        let system = """
        You are a strict router. Choose the single best capability for the user's request, ONLY from the \
        provided list. Reply with ONLY a JSON object: {"action":"executeCapability"|"clarify","capability":<id or null>,\
        "arguments":{...}}. Use "clarify" (capability null) if unsure. Never invent a capability id.
        Available inputs: \(inputModalities.map { $0.rawValue }.joined(separator: ",")).
        Capabilities: \(schemaJSON)
        """
        let req = ExternalInferenceRequest(
            model: nil,
            messages: [.init(role: .system, text: system), .init(role: .user, text: message)],
            generation: GenerationConfig(maxTokens: 120, temperature: 0.0),
            responseFormat: .json)
        guard let resp = try? await infer(req) else { return nil }
        let raw = ThinkingParser.parse(resp.outputText).answer ?? resp.outputText
        guard let obj = Self.extractJSON(raw) else { return nil }
        let action = (obj["action"] as? String) ?? "clarify"
        let prov = RouterProvenance(tier: "tier1-semantic", router: name)
        guard action == "executeCapability", let capStr = obj["capability"] as? String,
              schema.contains(where: { $0.capability == capStr }) else {
            return CapabilityIntent(action: .clarify, provenance: prov)
        }
        var args: [String: JSONValue] = [:]
        if let a = obj["arguments"] as? [String: Any] {
            for (k, v) in a { if let i = v as? Int { args[k] = .int(i) } else if let d = v as? Double { args[k] = .double(d) } else if let s = v as? String { args[k] = .string(s) } }
        }
        // inputRefs: reference the first attachment of the capability's needed modality (best-effort).
        var refs: [String] = []
        if let firstImage = inputModalities.firstIndex(of: .image), capStr.hasPrefix("image.") { refs = ["attachment_\(firstImage)"] }
        if let firstVideo = inputModalities.firstIndex(of: .video), capStr.hasPrefix("video.") { refs = ["attachment_\(firstVideo)"] }
        if let firstAudio = inputModalities.firstIndex(of: .audio), capStr.hasPrefix("audio.") { refs = ["attachment_\(firstAudio)"] }
        return CapabilityIntent(action: .executeCapability, capability: CapabilityID(capStr), inputRefs: refs,
                                arguments: args, provenance: prov)
    }

    static func extractJSON(_ s: String) -> [String: Any]? {
        guard let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}"), start < end else { return nil }
        let json = String(s[start...end])
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }
}
