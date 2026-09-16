import Foundation

// Incremental splitter that separates a model's reasoning/thinking span from its visible answer as text
// streams in, so the facade can emit `.reasoningDelta` vs `.token` honestly (it never invents reasoning —
// it only routes what the model actually emitted between `<think>`/`</think>`). Handles both real formats:
// explicit `<think>…</think> answer`, and implicit-open `reasoning… </think> answer` (chat template already
// emitted the opening tag). Stateless classification over the accumulated buffer keeps it correct even when
// a tag straddles a chunk boundary — a trailing partial tag is withheld until the next chunk completes it.
struct ReasoningStreamSplitter {
    private static let open = "<think>"
    private static let close = "</think>"
    private static let maxTagLen = 8   // "</think>"

    private var buffer = ""
    private var emittedVisible = 0
    private var emittedReasoning = 0

    /// Feed the next raw chunk. Returns the newly-safe (visible, reasoning) deltas to emit. Pass `final: true`
    /// on the last call to flush any withheld tail.
    mutating func ingest(_ chunk: String, final: Bool) -> (visible: String, reasoning: String) {
        buffer += chunk
        var (visible, reasoning, isThinking) = Self.classify(buffer)

        if !final {
            // Withhold the longest trailing substring that could be the start of a tag, from whichever
            // segment is currently growing (reasoning while thinking, else the visible answer).
            if isThinking {
                let hold = Self.trailingTagPrefixLength(of: reasoning)
                reasoning = String(reasoning.dropLast(hold))
            } else {
                let hold = Self.trailingTagPrefixLength(of: visible)
                visible = String(visible.dropLast(hold))
            }
        }

        let visibleDelta = String(visible.dropFirst(min(emittedVisible, visible.count)))
        let reasoningDelta = String(reasoning.dropFirst(min(emittedReasoning, reasoning.count)))
        emittedVisible = visible.count
        emittedReasoning = reasoning.count
        return (visibleDelta, reasoningDelta)
    }

    /// Classify the whole accumulated text into (visible answer, reasoning, stillThinking) for a single
    /// EXPLICIT `<think>…</think>` block. Live streaming only splits the explicit case — the implicit-open
    /// (DeepSeek-R1) format is indistinguishable from plain text until `</think>` arrives, and buffering
    /// until then would defeat streaming for models that emit no reasoning; the authoritative split for both
    /// formats is applied to the final result via `ThinkingParser` (which handles implicit-open).
    static func classify(_ s: String) -> (visible: String, reasoning: String, isThinking: Bool) {
        guard let openR = s.range(of: open) else { return (s, "", false) }
        let before = String(s[..<openR.lowerBound])
        let afterOpen = s[openR.upperBound...]
        if let cR = afterOpen.range(of: close) {
            return (before + String(afterOpen[cR.upperBound...]), String(afterOpen[..<cR.lowerBound]), false)
        }
        return (before, String(afterOpen), true)   // still thinking, no close yet
    }

    /// Longest suffix of `s` that is a proper prefix of `<think>` or `</think>` (so we don't emit a
    /// half-formed tag as content). 0 when the tail cannot begin a tag.
    static func trailingTagPrefixLength(of s: String) -> Int {
        let maxLen = min(maxTagLen - 1, s.count)
        guard maxLen > 0 else { return 0 }
        for len in stride(from: maxLen, through: 1, by: -1) {
            let suffix = String(s.suffix(len))
            if open.hasPrefix(suffix) || close.hasPrefix(suffix) { return len }
        }
        return 0
    }
}
