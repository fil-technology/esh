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
    case abstain                     // a SEMANTIC router declines to decide — defer to the safe default
                                     // (Tier-0 keeps its result; a pure Tier-1 falls back to clarify). An
                                     // abstain never executes and never counts as a router "decision".
}

/// When a router declines to execute (`clarify`), WHY it declined — the distinction that decides whether a
/// semantic fallback can add value (spec: "ambiguous vs unresolved"). This is part of the canonical routing
/// architecture, not an Apple-specific detail: it will matter for every future modality.
public enum ClarifyKind: String, Codable, Sendable {
    /// Tier-0 has enough evidence to know MULTIPLE registered capabilities plausibly match (or the request
    /// is multi-step / wrong-modality / has no actionable content). A semantic model cannot safely pick one
    /// — the USER must choose. Never escalate an `ambiguous` clarify to a router with execution authority.
    case ambiguous
    /// Tier-0 cannot confidently interpret the language (e.g. a non-Latin paraphrase), but the request may
    /// still describe ONE specific capability. Safe to escalate to a semantic router, whose proposal is then
    /// re-validated before execution.
    case unresolved
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
    /// For `clarify` only: whether it's `ambiguous` (user must choose) or `unresolved` (a semantic router
    /// may recover a single intent). Gates escalation — nil for non-clarify actions.
    public var clarifyKind: ClarifyKind?
    public var provenance: RouterProvenance
    /// UNTRUSTED router metadata only. Never gates execution.
    public var confidence: Double?
    /// For explicit multi-step requests: an ordered plan of further intents (each a registered capability).
    /// Empty for single-capability intents. Kept conservative — the router prefers clarify when unsure.
    public var plan: [CapabilityIntent]

    public init(action: RouterAction, capability: CapabilityID? = nil, inputRefs: [String] = [],
                arguments: [String: JSONValue] = [:], alternatives: [CapabilityID] = [], reason: String? = nil,
                clarifyKind: ClarifyKind? = nil,
                provenance: RouterProvenance, confidence: Double? = nil, plan: [CapabilityIntent] = []) {
        self.action = action
        self.capability = capability
        self.inputRefs = inputRefs
        self.arguments = arguments
        self.alternatives = alternatives
        self.reason = reason
        self.clarifyKind = clarifyKind
        self.provenance = provenance
        self.confidence = confidence
        self.plan = plan
    }

    public static func chat(_ provenance: RouterProvenance) -> CapabilityIntent { .init(action: .chat, provenance: provenance) }
}
