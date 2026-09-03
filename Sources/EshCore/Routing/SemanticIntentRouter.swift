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

/// Bumped when the capability set / arg schemas materially change, so routing evidence can go stale (§13).
public enum CapabilitySchemaVersion { public static let current = 1 }

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

// Shared constrained prompt + parser so EVERY router (resident LLM, Apple FM, FunctionGemma) targets the
// SAME canonical schema and CapabilityIntent — no per-router capability lists (spec §10).
public enum SemanticRouting {
    public static func systemInstruction(schema: [CapabilitySchemaEntry], modalities: [ModelModality]) -> String {
        let schemaJSON = (try? String(decoding: JSONCoding.encoder.encode(schema), as: UTF8.self)) ?? "[]"
        return """
        You are a strict router. Choose the single best capability for the user's request, ONLY from the \
        provided list. Reply with ONLY a JSON object: {"action":"executeCapability"|"clarify","capability":<id or null>,\
        "arguments":{...}}. Use "clarify" (capability null) if unsure. Never invent a capability id.
        Available inputs: \(modalities.map { $0.rawValue }.joined(separator: ",")).
        Capabilities: \(schemaJSON)
        """
    }

    /// Parse a router's raw text into a validated-shape intent (capability must be in `schema`, else clarify).
    public static func parse(_ raw: String, schema: [CapabilitySchemaEntry], modalities: [ModelModality],
                             routerName: String) -> CapabilityIntent {
        let prov = RouterProvenance(tier: "tier1-semantic", router: routerName)
        guard let obj = extractJSON(raw) else { return CapabilityIntent(action: .clarify, provenance: prov) }
        let action = (obj["action"] as? String) ?? "clarify"
        guard action == "executeCapability", let capStr = obj["capability"] as? String,
              schema.contains(where: { $0.capability == capStr }) else {
            return CapabilityIntent(action: .clarify, provenance: prov)
        }
        var args: [String: JSONValue] = [:]
        if let a = obj["arguments"] as? [String: Any] {
            for (k, v) in a { if let i = v as? Int { args[k] = .int(i) } else if let d = v as? Double { args[k] = .double(d) } else if let s = v as? String { args[k] = .string(s) } }
        }
        var refs: [String] = []
        if let i = modalities.firstIndex(of: .image), capStr.hasPrefix("image.") { refs = ["attachment_\(i)"] }
        if let i = modalities.firstIndex(of: .video), capStr.hasPrefix("video.") { refs = ["attachment_\(i)"] }
        if let i = modalities.firstIndex(of: .audio), capStr.hasPrefix("audio.") { refs = ["attachment_\(i)"] }
        return CapabilityIntent(action: .executeCapability, capability: CapabilityID(capStr), inputRefs: refs, arguments: args, provenance: prov)
    }

    static func extractJSON(_ s: String) -> [String: Any]? {
        guard let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}"), start < end else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(String(s[start...end]).utf8))) as? [String: Any]
    }
}

/// Tier-1 router backed by Apple Foundation Models (on-device `SystemLanguageModel`, never PCC). Zero
/// download where macOS supports it. Output is parsed + validated identically to every other router.
public struct AppleFMSemanticRouter: SemanticIntentRouter {
    public let name = "apple-foundation"
    private let generate: @Sendable (_ prompt: String, _ instructions: String) async throws -> String
    /// Default uses the real on-device service; injectable for tests.
    public init(generate: (@Sendable (_ prompt: String, _ instructions: String) async throws -> String)? = nil) {
        self.generate = generate ?? { prompt, instructions in
            try await AppleIntelligenceService().generate(prompt: prompt, instructions: instructions)
        }
    }
    public func propose(message: String, inputModalities: [ModelModality], schema: [CapabilitySchemaEntry]) async -> CapabilityIntent? {
        guard !schema.isEmpty else { return nil }
        let sys = SemanticRouting.systemInstruction(schema: schema, modalities: inputModalities)
        guard let raw = try? await generate(message, sys) else { return nil }
        return SemanticRouting.parse(SanitizeThinking(raw), schema: schema, modalities: inputModalities, routerName: name)
    }
    private func SanitizeThinking(_ s: String) -> String { ThinkingParser.parse(s).answer ?? s }
}

/// Default Tier-1 router using a resident LLM constrained to emit a single JSON intent from the schema.
/// Zero extra download (uses whatever LLM is resident). Output is parsed defensively + validated by the
/// resolver; a malformed/for-unknown-capability answer is discarded (no false execution).
public struct ResidentLLMSemanticRouter: SemanticIntentRouter {
    public typealias InferFn = @Sendable (ExternalInferenceRequest) async throws -> ExternalInferenceResponse
    public let name: String
    private let infer: InferFn
    private let modelID: String?     // nil → Auto/resident; set to force a specific router model (e.g. FunctionGemma)
    public init(name: String = "resident-llm", modelID: String? = nil, infer: @escaping InferFn) {
        self.name = name; self.modelID = modelID; self.infer = infer
    }

    public func propose(message: String, inputModalities: [ModelModality], schema: [CapabilitySchemaEntry]) async -> CapabilityIntent? {
        guard !schema.isEmpty else { return nil }
        let system = SemanticRouting.systemInstruction(schema: schema, modalities: inputModalities)
        let req = ExternalInferenceRequest(
            model: modelID,
            messages: [.init(role: .system, text: system), .init(role: .user, text: message)],
            generation: GenerationConfig(maxTokens: 120, temperature: 0.0),
            responseFormat: .json)
        guard let resp = try? await infer(req) else { return nil }
        let raw = ThinkingParser.parse(resp.outputText).answer ?? resp.outputText
        return SemanticRouting.parse(raw, schema: schema, modalities: inputModalities, routerName: name)
    }
}
