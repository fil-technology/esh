import Foundation

// esh 2.1 UCMR, Stage 2 — capability-aware model resolution. Consumes the (until now dormant)
// ModelSpec.capabilities data so a request without an explicit model can still pick the right INSTALLED
// model for its capability — a vision model for image.understand, an embedding model for language.embed,
// etc. — instead of assuming an LLM. This is the "wire existing modality data into selection" step; the
// full Scheduler v2 ranking (evidence/latency/quality) builds on this later.

public struct CapabilityModelResolver: Sendable {
    public init() {}

    /// The capability filter an installed model must satisfy, or nil when the capability needs no model
    /// (e.g. image.ocr is served by Apple Vision) or is not model-selectable here.
    public func requiredFilter(for capability: CapabilityID) -> ModelCapabilityFilter? {
        switch capability {
        case .languageEmbed: return .embedding
        case .languageRerank: return .rerank
        case .imageUnderstand: return .imageUnderstanding
        case .languageGenerate, .languageReason, .languageSummarize,
             .languageTranslate, .languageClassify, .languageExtract,
             .vectorGenerate:
            return .chat
        default:
            return nil   // image.ocr (Apple Vision, no model), image.generate, etc. — not resolved here yet
        }
    }

    /// Choose an installed model id for the capability, or nil if none is suitable / none is needed.
    public func resolveModelID(capability: CapabilityID, from installs: [ModelInstall]) -> String? {
        guard let filter = requiredFilter(for: capability) else { return nil }
        if let match = installs.first(where: { $0.spec.capabilities.supports(capability: filter) }) {
            return match.id
        }
        // Fallback for chat-class capabilities: older specs may not declare capabilities explicitly, so
        // accept any text-task model. Non-text capabilities require an explicit, declared model.
        if filter == .chat {
            return installs.first(where: { $0.spec.task == .text })?.id
        }
        return nil
    }
}
