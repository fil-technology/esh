import Foundation

// esh 2.1 — Capability Intent Router (spec 86eyucfbu). The canonical, additive typed routing result:
// "chat message + typed attachments → CapabilityIntent". A router only PROPOSES an intent from
// capabilities that actually exist; esh validates everything independently before execution. Confidence
// is untrusted router metadata, never the execution gate.

public enum RouterAction: String, Codable, Sendable {
    case chat                        // ordinary language chat — not a capability execution
    case executeCapability           // run a single capability now
    case installProviderThenExecute  // supported, but the provider/model must be installed first
    case clarify                     // ambiguous — ask a concise question rather than guess
    case unsupported                 // esh cannot perform this (or it belongs to the agent layer)
}

public struct RouterProvenance: Codable, Sendable, Equatable {
    public var tier: String          // "tier0-deterministic", "tier1-semantic", …
    public var router: String        // "rules", "apple-foundation", "functiongemma", resident model id…
    public init(tier: String, router: String) { self.tier = tier; self.router = router }
}

public struct CapabilityIntent: Codable, Sendable, Equatable {
    public var action: RouterAction
    /// The chosen capability (nil for chat/clarify/unsupported).
    public var capability: CapabilityID?
    /// References to the request's typed inputs the capability consumes, e.g. ["attachment_0"].
    public var inputRefs: [String]
    /// Extracted, typed arguments (e.g. {"scale": 2}). Validated against the capability schema later.
    public var arguments: [String: JSONValue]
    /// Other plausible capabilities (for clarify UIs / alternatives).
    public var alternatives: [CapabilityID]
    /// Why clarification/unsupported — a concise, user-facing reason.
    public var reason: String?
    public var provenance: RouterProvenance
    /// UNTRUSTED router metadata only. Never gates execution.
    public var confidence: Double?
    /// For explicit multi-step requests: an ordered plan of further intents (each a registered capability).
    /// Empty for single-capability intents. Kept conservative — the router prefers clarify when unsure.
    public var plan: [CapabilityIntent]

    public init(action: RouterAction, capability: CapabilityID? = nil, inputRefs: [String] = [],
                arguments: [String: JSONValue] = [:], alternatives: [CapabilityID] = [], reason: String? = nil,
                provenance: RouterProvenance, confidence: Double? = nil, plan: [CapabilityIntent] = []) {
        self.action = action
        self.capability = capability
        self.inputRefs = inputRefs
        self.arguments = arguments
        self.alternatives = alternatives
        self.reason = reason
        self.provenance = provenance
        self.confidence = confidence
        self.plan = plan
    }

    public static func chat(_ provenance: RouterProvenance) -> CapabilityIntent { .init(action: .chat, provenance: provenance) }
}
