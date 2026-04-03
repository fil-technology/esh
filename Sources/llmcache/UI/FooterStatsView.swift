import Foundation
import LLMCacheCore

enum FooterStatsView {
    static func render(state: AppState) {
        let ctx = state.metrics.contextTokens.map(String.init) ?? "-"
        let ttft = state.metrics.ttftMilliseconds.map { "\($0)ms" } ?? "-"
        let toks = state.metrics.tokensPerSecond.map { String(format: "%.1f tok/s", $0) } ?? "-"
        let cache = state.metrics.cacheSizeBytes.map(ByteFormatting.string(for:)) ?? "-"
        let ratio = state.metrics.compressionRatio.map { String(format: "%.1fx", $0) } ?? "-"

        print("-----")
        print("\(state.backendLabel) | \(state.modelLabel) | \(state.cacheMode) | ctx \(ctx) | ttft \(ttft) | \(toks) | cache \(cache) \(ratio) | session \(state.sessionName)")
    }
}
