import Foundation
import Testing
@testable import EshCore

// esh 2.1 Router Auto — the "safe Apple semantic fallback": the semantic router is a high-precision proposer
// that must ABSTAIN rather than eagerly classify. These lock the abstention contract so a router can never
// turn ordinary chat / out-of-scope / uncertain requests into an execution.
@Suite
struct SemanticRoutingAbstainTests {
    private let schema = [
        CapabilitySchemaEntry(capability: "image.upscale", description: "Increase an image's resolution",
                              inputModalities: ["image"], arguments: ["scale": "integer 2 or 4"]),
        CapabilitySchemaEntry(capability: "image.segment", description: "Remove background",
                              inputModalities: ["image"], arguments: [:]),
    ]

    @Test func explicitAbstainDecisionParsesToAbstain() {
        let intent = SemanticRouting.parse(#"{"decision":"abstain","reason":"ordinary chat"}"#,
                                           schema: schema, modalities: [], routerName: "apple-foundation")
        #expect(intent.action == .abstain)
        #expect(intent.reason == "ordinary chat")
    }

    @Test func confidentExecuteParsesWithCapabilityAndArgs() {
        let intent = SemanticRouting.parse(#"{"decision":"executeCapability","capability":"image.upscale","arguments":{"scale":2}}"#,
                                           schema: schema, modalities: [.image], routerName: "apple-foundation")
        #expect(intent.action == .executeCapability)
        #expect(intent.capability == .imageUpscale)
        #expect(intent.arguments["scale"] == .int(2))
        #expect(intent.inputRefs == ["attachment_0"])
    }

    @Test func unknownCapabilityAbstainsRatherThanFabricatingExecution() {
        // A capability NOT in the schema must never become an execution.
        let intent = SemanticRouting.parse(#"{"decision":"executeCapability","capability":"image.deblur"}"#,
                                           schema: schema, modalities: [.image], routerName: "apple-foundation")
        #expect(intent.action == .abstain)
    }

    @Test func unparseableOutputAbstains() {
        let intent = SemanticRouting.parse("I think you want to upscale this!",
                                           schema: schema, modalities: [.image], routerName: "apple-foundation")
        #expect(intent.action == .abstain)
    }

    @Test func legacyActionKeyStillAccepted() {
        // Back-compat: routers that emit "action" instead of "decision" still parse.
        let intent = SemanticRouting.parse(#"{"action":"executeCapability","capability":"image.segment"}"#,
                                           schema: schema, modalities: [.image], routerName: "resident-llm")
        #expect(intent.action == .executeCapability)
        #expect(intent.capability == .imageSegment)
    }

    @Test func appleRouterAbstainsWhenModelDeclines() async {
        let router = AppleFMSemanticRouter(generate: { _, _ in #"{"decision":"abstain","reason":"out of scope"}"# })
        let intent = await router.propose(message: "deploy my site", inputModalities: [], schema: schema)
        #expect(intent?.action == .abstain)
    }

    @Test func appleRouterProposesWhenConfident() async {
        let router = AppleFMSemanticRouter(generate: { _, _ in #"{"decision":"executeCapability","capability":"image.segment"}"# })
        let intent = await router.propose(message: "cut out the background", inputModalities: [.image], schema: schema)
        #expect(intent?.action == .executeCapability)
        #expect(intent?.capability == .imageSegment)
    }

    // MARK: - Tier-0 ambiguous vs unresolved split (escalation gate)

    @Test func genericImproveIsAmbiguousNotUnresolved() {
        // "make this better" on an image → AMBIGUOUS (multiple registered image transforms plausible) → must
        // NOT escalate to a semantic router (that's where the eager guesses came from).
        let intent = DeterministicIntentRouter().route(message: "make this better", inputModalities: [.image])
        #expect(intent.action == .clarify)
        #expect(intent.clarifyKind == .ambiguous)
    }

    @Test func multiStepIsAmbiguous() {
        let intent = DeterministicIntentRouter().route(message: "Remove the background and upscale it 2×", inputModalities: [.image])
        #expect(intent.action == .clarify)
        #expect(intent.clarifyKind == .ambiguous)
    }

    @Test func nonLatinAttachmentIsUnresolvedSoItCanEscalate() {
        // Russian "improve this" — Tier-0 can't read it; it's UNRESOLVED so a multilingual router MAY recover
        // a specific capability (the Safety Validator then decides). Escalation is allowed here.
        let intent = DeterministicIntentRouter().route(message: "Что здесь написано?", inputModalities: [.image])
        #expect(intent.action == .clarify)
        #expect(intent.clarifyKind == .unresolved)
    }

    @Test func englishNoiseIsAmbiguousNotUnresolved() {
        // "here you go" with an image — parseable English, no actionable content → AMBIGUOUS (nothing to
        // recover; escalating only invites a hallucination).
        let intent = DeterministicIntentRouter().route(message: "here you go", inputModalities: [.image])
        #expect(intent.action == .clarify)
        #expect(intent.clarifyKind == .ambiguous)
    }
}
