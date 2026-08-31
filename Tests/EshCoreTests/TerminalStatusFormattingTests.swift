import Foundation
import Testing
@testable import EshCore

@Suite
struct TerminalStatusFormattingTests {

    @Test
    func executionSummaryIncludesOnlyMeasuredFields() {
        let m = Metrics(tokensPerSecond: 38, promptTokens: 100, generationTokens: 827, cacheHit: true)
        let s = TerminalStatusFormatting.executionSummary(metrics: m, latencySeconds: 1.8)
        #expect(s.contains("1.8s"))
        #expect(s.contains("927 tokens (100+827)"))
        #expect(s.contains("38 tok/s"))
        #expect(s.contains("KV hit"))
    }

    @Test
    func executionSummaryOmitsUnknownFields() {
        let s = TerminalStatusFormatting.executionSummary(metrics: Metrics(), latencySeconds: nil)
        #expect(s.isEmpty)   // nothing measured → nothing claimed
    }

    @Test
    func residencyLineRendersResidencyContextMemory() {
        let s = TerminalStatusFormatting.residencyLine(
            residency: .weightsResident, contextUsed: 12000, contextLimit: 32000, memoryBytes: 18_400_000_000)
        #expect(s.contains("weights resident"))
        #expect(s.contains("12K/32K ctx"))
    }

    @Test
    func residencyLineHandleCachedIsHonest() {
        let s = TerminalStatusFormatting.residencyLine(residency: .handleCached, contextUsed: nil, contextLimit: nil, memoryBytes: nil)
        #expect(s == "handle cached")   // never claims residency it doesn't have
    }

    @Test
    func compactTokens() {
        #expect(TerminalStatusFormatting.compactTokens(512) == "512")
        #expect(TerminalStatusFormatting.compactTokens(12000) == "12K")
        #expect(TerminalStatusFormatting.compactTokens(32768) == "33K")
    }

    @Test
    func slashCommandParsingCoversTheMockupSet() {
        #expect(SlashCommand.parse("/model") == .model(nil))
        #expect(SlashCommand.parse("/model qwen-3-5-9b") == .model("qwen-3-5-9b"))
        #expect(SlashCommand.parse("/auto") == .auto)
        #expect(SlashCommand.parse("/new") == .new)
        #expect(SlashCommand.parse("/sessions") == .sessions)
        #expect(SlashCommand.parse("/status") == .status)
        #expect(SlashCommand.parse("/context") == .context)
        #expect(SlashCommand.parse("/performance") == .performance)
        #expect(SlashCommand.parse("/perf") == .performance)
        #expect(SlashCommand.parse("/settings") == .settings)
        #expect(SlashCommand.parse("/doctor") == .doctor)
        #expect(SlashCommand.parse("/clear") == .clear)
        #expect(SlashCommand.parse("/help") == .help)
        #expect(SlashCommand.parse("/exit") == .exit)
        #expect(SlashCommand.parse("/MODEL") == .model(nil))   // case-insensitive
    }

    @Test
    func nonSlashInputIsNotACommand() {
        #expect(SlashCommand.parse("hello world") == nil)
        #expect(SlashCommand.parse("what is /usr/bin?") == nil)   // slash mid-line is a message
    }

    @Test
    func unknownSlashRoutesToOther() {
        #expect(SlashCommand.parse("/use-model foo") == .other("/use-model foo"))
    }
}
