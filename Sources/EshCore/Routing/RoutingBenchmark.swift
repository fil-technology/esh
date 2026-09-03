import Foundation

// esh 2.1 — Capability routing benchmark (spec 86eyucfbu §6/§7). A first-class, data-driven dataset +
// harness with metrics measured SEPARATELY. False execution (confidently running the wrong transformation)
// is the most costly error, so it's tracked explicitly and must stay at zero for the deterministic tier.
// The dataset grows over time; this is the seed covering the spec's categories.

public struct RoutingCase: Sendable, Equatable {
    public var message: String
    public var inputs: [ModelModality]
    public var expectedAction: RouterAction
    public var expectedCapability: CapabilityID?   // for executeCapability
    public var category: String
    public init(_ message: String, inputs: [ModelModality] = [], expect action: RouterAction,
                capability: CapabilityID? = nil, category: String) {
        self.message = message; self.inputs = inputs; self.expectedAction = action
        self.expectedCapability = capability; self.category = category
    }
}

public struct RoutingMetrics: Sendable, Equatable {
    public var total = 0
    public var actionCorrect = 0
    public var capabilityCases = 0          // expected == executeCapability
    public var capabilityCorrect = 0        // predicted capability matches on those
    public var falseExecutions = 0          // predicted execute when it shouldn't have, or wrong capability
    public var clarifyExpected = 0, clarifyPredicted = 0, clarifyCorrect = 0
    public var chatExpected = 0, chatCorrect = 0
    public var unsupportedExpected = 0, unsupportedCorrect = 0
    public var failures: [String] = []      // human-readable mispredictions for triage

    public var actionAccuracy: Double { total == 0 ? 0 : Double(actionCorrect) / Double(total) }
    public var capabilitySelectionAccuracy: Double { capabilityCases == 0 ? 1 : Double(capabilityCorrect) / Double(capabilityCases) }
    public var falseExecutionRate: Double { total == 0 ? 0 : Double(falseExecutions) / Double(total) }
    public var clarifyRecall: Double { clarifyExpected == 0 ? 1 : Double(clarifyCorrect) / Double(clarifyExpected) }
    public var clarifyPrecision: Double { clarifyPredicted == 0 ? 1 : Double(clarifyCorrect) / Double(clarifyPredicted) }
    public var chatAccuracy: Double { chatExpected == 0 ? 1 : Double(chatCorrect) / Double(chatExpected) }
    public var unsupportedAccuracy: Double { unsupportedExpected == 0 ? 1 : Double(unsupportedCorrect) / Double(unsupportedExpected) }
}

public enum RoutingBenchmark {
    /// Run the deterministic router over the cases and compute separated metrics. `treatClarifyPlanAsExecute`
    /// is false: a clarify carrying a proposed multi-step plan is still a clarify (conservative).
    public static func run(_ cases: [RoutingCase], router: DeterministicIntentRouter = .init()) -> RoutingMetrics {
        var m = RoutingMetrics()
        for c in cases {
            m.total += 1
            let intent = router.route(message: c.message, inputModalities: c.inputs)
            let predicted = intent.action
            // Treat installProviderThenExecute like executeCapability for router-accuracy (both "run this cap").
            let predictedExecutes = (predicted == .executeCapability || predicted == .installProviderThenExecute)
            let expectedExecutes = (c.expectedAction == .executeCapability || c.expectedAction == .installProviderThenExecute)

            if predicted == c.expectedAction { m.actionCorrect += 1 }

            if expectedExecutes {
                m.capabilityCases += 1
                if predictedExecutes && intent.capability == c.expectedCapability { m.capabilityCorrect += 1 }
                else { m.failures.append("[\(c.category)] \"\(c.message)\" → \(predicted)/\(intent.capability?.rawValue ?? "-") (want \(c.expectedCapability?.rawValue ?? "-"))") }
            } else {
                // Expected NOT to execute. Any execution here is a FALSE EXECUTION.
                if predictedExecutes {
                    m.falseExecutions += 1
                    m.failures.append("FALSE-EXEC [\(c.category)] \"\(c.message)\" → \(intent.capability?.rawValue ?? "-") (want \(c.expectedAction))")
                }
            }
            // Wrong-capability execution also counts as a false execution.
            if expectedExecutes, predictedExecutes, intent.capability != c.expectedCapability { m.falseExecutions += 1 }

            if c.expectedAction == .clarify { m.clarifyExpected += 1; if predicted == .clarify { m.clarifyCorrect += 1 } }
            if predicted == .clarify { m.clarifyPredicted += 1 }
            if c.expectedAction == .chat { m.chatExpected += 1; if predicted == .chat { m.chatCorrect += 1 } }
            if c.expectedAction == .unsupported { m.unsupportedExpected += 1; if predicted == .unsupported { m.unsupportedCorrect += 1 } }
        }
        return m
    }

    /// Seed dataset covering the spec's categories. Cases Tier 0 cannot resolve with high certainty are
    /// labelled `clarify` on purpose — clarification is the correct safe answer, not a failure.
    public static let seed: [RoutingCase] = [
        // Explicit
        .init("Upscale this 2×", inputs: [.image], expect: .executeCapability, capability: .imageUpscale, category: "explicit"),
        .init("upscale this image", inputs: [.image], expect: .executeCapability, capability: .imageUpscale, category: "explicit"),
        .init("Remove the background", inputs: [.image], expect: .executeCapability, capability: .imageSegment, category: "explicit"),
        .init("What does this screenshot say?", inputs: [.image], expect: .executeCapability, capability: .imageOCR, category: "explicit"),
        .init("Generate a watercolor fox", expect: .executeCapability, capability: .imageGenerate, category: "explicit"),
        .init("Create an SVG logo of a fox", expect: .executeCapability, capability: .vectorGenerate, category: "explicit"),
        .init("Transcribe this", inputs: [.audio], expect: .executeCapability, capability: .audioTranscribe, category: "explicit"),
        .init("Who spoke when?", inputs: [.audio], expect: .executeCapability, capability: .audioDiarize, category: "explicit"),
        .init("What happens in this video?", inputs: [.video], expect: .executeCapability, capability: .videoUnderstand, category: "explicit"),
        // Paraphrases
        .init("make this bigger", inputs: [.image], expect: .executeCapability, capability: .imageUpscale, category: "paraphrase"),
        .init("increase the resolution to 4x", inputs: [.image], expect: .executeCapability, capability: .imageUpscale, category: "paraphrase"),
        .init("cut out the background", inputs: [.image], expect: .executeCapability, capability: .imageSegment, category: "paraphrase"),
        .init("what's written here?", inputs: [.image], expect: .executeCapability, capability: .imageOCR, category: "paraphrase"),
        .init("separate the speakers", inputs: [.audio], expect: .executeCapability, capability: .audioDiarize, category: "paraphrase"),
        // Bare question about an attachment → understand
        .init("what is in this image?", inputs: [.image], expect: .executeCapability, capability: .imageUnderstand, category: "understand"),
        .init("describe this", inputs: [.image], expect: .executeCapability, capability: .imageUnderstand, category: "understand"),
        // Ambiguity → clarify (must NOT guess a transformation)
        .init("make this clearer", inputs: [.image], expect: .clarify, category: "ambiguous"),
        .init("improve this", inputs: [.image], expect: .clarify, category: "ambiguous"),
        .init("make this better", inputs: [.image], expect: .clarify, category: "ambiguous"),
        .init("enhance this", inputs: [.image], expect: .clarify, category: "ambiguous"),
        .init("fix this", inputs: [.image], expect: .clarify, category: "ambiguous"),
        .init("here you go", inputs: [.image], expect: .clarify, category: "ambiguous"),   // attachment, no verb
        // Multi-capability → clarify with proposed plan (conservative)
        .init("Remove the background and upscale it 2×", inputs: [.image], expect: .clarify, category: "multi"),
        .init("transcribe this and separate the speakers", inputs: [.audio], expect: .clarify, category: "multi"),
        // Unsupported / agent boundary
        .init("deploy this to production", expect: .unsupported, category: "unsupported"),
        .init("open the browser and click login", expect: .unsupported, category: "unsupported"),
        .init("run a loop until the tests pass", expect: .unsupported, category: "unsupported"),
        // Normal chat MUST stay chat (false-tool-call guard)
        .init("Explain recursion", expect: .chat, category: "chat"),
        .init("What's the capital of France?", expect: .chat, category: "chat"),
        .init("Write a haiku about autumn", expect: .chat, category: "chat"),
        .init("Thanks, that's helpful", expect: .chat, category: "chat"),
        .init("How do I center a div?", expect: .chat, category: "chat"),
        // Chat that mentions capability-ish words but has no attachment/real intent
        .init("what is image upscaling?", expect: .chat, category: "chat"),
    ]
}
