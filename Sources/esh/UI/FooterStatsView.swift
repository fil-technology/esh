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
        let scroll = state.transcriptScrollOffset > 0
            ? "\(TerminalUIStyle.amber)scroll +\(state.transcriptScrollOffset)\(TerminalUIStyle.reset)"
            : "\(TerminalUIStyle.faint)follow live\(TerminalUIStyle.reset)"
        let verboseSegments = [
            "\(TerminalUIStyle.faint)ctx\(TerminalUIStyle.reset) \(TerminalUIStyle.ink)\(ctx)\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.faint)ttft\(TerminalUIStyle.reset) \(TerminalUIStyle.ink)\(ttft)\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.faint)tok/s\(TerminalUIStyle.reset) \(TerminalUIStyle.ink)\(tokPerSecond)\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.faint)cache\(TerminalUIStyle.reset) \(TerminalUIStyle.ink)\(cache)\(TerminalUIStyle.reset)",
            scroll,
            autosave
        ]
        let compactSegments = [
            "\(TerminalUIStyle.faint)ctx\(TerminalUIStyle.reset) \(ctx)",
            "\(TerminalUIStyle.faint)t/s\(TerminalUIStyle.reset) \(tokPerSecond)",
            "\(TerminalUIStyle.faint)cache\(TerminalUIStyle.reset) \(cache)",
            scroll,
            autosave
        ]
        let minimalSegments = [
            scroll,
            "\(TerminalUIStyle.faint)t/s\(TerminalUIStyle.reset) \(tokPerSecond)",
            autosave
        ]

        let separator = "  \(TerminalUIStyle.faint)•\(TerminalUIStyle.reset)  "
        for candidate in [verboseSegments, compactSegments, minimalSegments] {
            let footer = candidate.joined(separator: separator)
            if TerminalUIStyle.visibleWidth(of: footer) <= width {
                return footer
            }
        }

        return TerminalUIStyle.truncateVisible(minimalSegments.joined(separator: separator), limit: width)
    }
}
