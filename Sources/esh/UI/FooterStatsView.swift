import Foundation
import EshCore

enum FooterStatsView {
    static func renderedLine(state: ChatScreenState, width: Int) -> String {
        let ctx = state.metrics.contextTokens.map(String.init) ?? "-"
        let ttft = state.metrics.ttftMilliseconds.map { String(format: "%.1fms", $0) } ?? "-"
        let tokPerSecond = state.metrics.tokensPerSecond.map { String(format: "%.1f", $0) } ?? "-"
        let cache = state.metrics.cacheSizeBytes.map(ByteFormatting.string(for:)) ?? "-"

        let autosave = state.autosaveEnabled
            ? "\(TerminalUIStyle.green)autosave on\(TerminalUIStyle.reset)"
            : "\(TerminalUIStyle.faint)autosave off\(TerminalUIStyle.reset)"
        let segments = [
            "\(TerminalUIStyle.faint)ctx\(TerminalUIStyle.reset) \(TerminalUIStyle.ink)\(ctx)\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.faint)ttft\(TerminalUIStyle.reset) \(TerminalUIStyle.ink)\(ttft)\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.faint)tok/s\(TerminalUIStyle.reset) \(TerminalUIStyle.ink)\(tokPerSecond)\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.faint)cache\(TerminalUIStyle.reset) \(TerminalUIStyle.ink)\(cache)\(TerminalUIStyle.reset)",
            autosave
        ]
        let footer = segments.joined(separator: "  \(TerminalUIStyle.faint)•\(TerminalUIStyle.reset)  ")
        return TerminalUIStyle.truncateVisible(footer, limit: width)
    }
}
