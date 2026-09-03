import Foundation
import Testing
@testable import EshCore

@Suite
struct DeterministicIntentRouterTests {
    let router = DeterministicIntentRouter()

    private func route(_ m: String, _ mods: [ModelModality] = []) -> CapabilityIntent {
        router.route(message: m, inputModalities: mods)
    }

    @Test
    func routesTheHeadlineUpscaleWithScaleArgument() {
        let i = route("Upscale this 2×", [.image])
        #expect(i.action == .executeCapability)
        #expect(i.capability == .imageUpscale)
        #expect(i.arguments["scale"] == .int(2))
        #expect(i.inputRefs == ["attachment_0"])
    }

    @Test
    func routesExplicitSingleCapabilities() {
        #expect(route("Remove the background", [.image]).capability == .imageSegment)
        #expect(route("What does this screenshot say?", [.image]).capability == .imageOCR)
        #expect(route("who spoke when?", [.audio]).capability == .audioDiarize)
        #expect(route("transcribe this", [.audio]).capability == .audioTranscribe)
        #expect(route("what happens in this video?", [.video]).capability == .videoUnderstand)
        #expect(route("what is in this image?", [.image]).capability == .imageUnderstand)
    }

    @Test
    func routesGenerationByVerbPlusVisualNoun() {
        #expect(route("Generate a watercolor fox").capability == .imageGenerate)
        #expect(route("Create an SVG logo of a fox").capability == .vectorGenerate)
        #expect(route("draw a picture of a sunset").capability == .imageGenerate)
        // Not visual generation → chat, not a false image.generate.
        #expect(route("generate a poem about autumn").action == .chat)
        #expect(route("write a haiku").action == .chat)
    }

    @Test
    func ambiguousImageEditsClarifyNeverGuess() {
        for m in ["make this clearer", "improve this", "enhance this", "make this better", "fix this"] {
            let i = route(m, [.image])
            #expect(i.action == .clarify, "\(m) should clarify, got \(i.action)")
        }
    }

    @Test
    func multiStepAsksToConfirmWithAProposedPlan() {
        let i = route("Remove the background and upscale it 2×", [.image])
        #expect(i.action == .clarify)
        #expect(i.plan.map { $0.capability } == [.imageSegment, .imageUpscale])   // safe ordering
    }

    @Test
    func agentTasksAreUnsupportedNotMisrouted() {
        #expect(route("deploy this to production").action == .unsupported)
        #expect(route("open the browser and click login").action == .unsupported)
    }

    @Test
    func ordinaryChatStaysChat() {
        for m in ["Explain recursion", "What's the capital of France?", "Thanks!", "what is image upscaling?"] {
            #expect(route(m).action == .chat, "\(m) should be chat")
        }
    }

    @Test
    func attachmentWithNoVerbClarifies() {
        #expect(route("here you go", [.image]).action == .clarify)
    }
}

@Suite
struct RoutingBenchmarkTests {
    @Test
    func seedBenchmarkHasZeroFalseExecutions() {
        let m = RoutingBenchmark.run(RoutingBenchmark.seed)
        // The core acceptance requirement: never confidently run the wrong transformation.
        #expect(m.falseExecutions == 0, "false executions: \(m.failures.filter { $0.hasPrefix("FALSE") })")
        // Deterministic tier should also get the clear cases right.
        #expect(m.capabilitySelectionAccuracy >= 0.95, "cap accuracy \(m.capabilitySelectionAccuracy): \(m.failures)")
        #expect(m.chatAccuracy == 1.0, "chat: \(m.failures)")
        #expect(m.unsupportedAccuracy == 1.0)
        #expect(m.clarifyRecall >= 0.8)
        #expect(m.total == RoutingBenchmark.seed.count)
    }
}
