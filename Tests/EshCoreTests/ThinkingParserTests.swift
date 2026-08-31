import Foundation
import Testing
@testable import EshCore

@Suite
struct ThinkingParserTests {
    @Test
    func explicitThinkBlockSplits() {
        let r = ThinkingParser.parse("<think>compute 7*7 = 49</think>The answer is 49.")
        #expect(r.reasoning == "compute 7*7 = 49")
        #expect(r.answer == "The answer is 49.")
        #expect(r.isThinking == false)
    }

    @Test
    func implicitOpenChainIsDetected() {
        // DeepSeek-R1 case: chat template already emitted <think>, so generation begins inside it and
        // only a trailing </think> is present. This must NOT leak into the answer.
        let r = ThinkingParser.parse("Alright, the user asked... let me respond.\n</think>\nI'm here to help!")
        #expect(r.reasoning?.contains("Alright") == true)
        #expect(r.answer == "I'm here to help!")
        #expect(r.answer?.contains("</think>") == false)   // the bug: stray tag must be gone
    }

    @Test
    func stillThinkingWhenNoCloseTag() {
        let r = ThinkingParser.parse("<think>still working on it")
        #expect(r.isThinking == true)
        #expect(r.answer == nil)
        #expect(r.reasoning == "still working on it")
    }

    @Test
    func plainAnswerHasNoReasoning() {
        let r = ThinkingParser.parse("Just a normal answer.")
        #expect(r.reasoning == nil)
        #expect(r.answer == "Just a normal answer.")
        #expect(r.isThinking == false)
    }

    @Test
    func collapsedSummaryDescribesTheChain() {
        let s = ThinkingParser.collapsedSummary("line one\nline two\nline three")
        #expect(s.contains("Reasoning"))
        #expect(s.contains("3 lines"))
        #expect(s.contains("/think"))
    }
}
