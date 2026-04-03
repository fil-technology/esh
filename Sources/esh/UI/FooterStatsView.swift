import Foundation
import EshCore

enum FooterStatsView {
    static func renderedLine(state: ChatScreenState, width: Int) -> String {
        let ctx = state.metrics.contextTokens.map(String.init) ?? "-"
        let ttft = state.metrics.ttftMilliseconds.map { String(format: "%.1fms", $0) } ?? "-"
        let tokPerSecond = state.metrics.tokensPerSecond.map { String(format: "%.1f", $0) } ?? "-"
        let cache = state.metrics.cacheSizeBytes.map(ByteFormatting.string(for:)) ?? "-"

        let autosave = state.autosaveEnabled ? "autosave on" : "autosave off"
        let footer = "\(state.backendLabel) | \(state.modelLabel) | \(state.cacheMode) | ctx \(ctx) | ttft \(ttft) | tok/s \(tokPerSecond) | cache \(cache) | session \(state.sessionName) | \(autosave) | \(state.statusText)"
        return truncate(footer, width: width)
    }

    private static func truncate(_ value: String, width: Int) -> String {
        guard value.count > width else { return value }
        let index = value.index(value.startIndex, offsetBy: max(width - 1, 0))
        return String(value[..<index])
    }
}
