import Foundation

/// Pure, testable parsing of assistant output into an optional reasoning (thinking) chain and the
/// visible answer. Handles the two real formats seen in the wild:
///   - explicit `<think>…</think> answer` (e.g. qwen3.5), and
///   - implicit-open `reasoning… </think> answer` where the model's chat template already emitted the
///     opening `<think>`, so generation *begins inside* the reasoning (e.g. DeepSeek-R1). Without
///     handling the second case, the whole chain — including a stray `</think>` — leaks into the
///     answer, which is the bug the Terminal UX showed.
public enum ThinkingParser {
    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    public struct Result: Equatable, Sendable {
        public var reasoning: String?
        public var answer: String?
        /// True while a reasoning chain is open and not yet closed (still thinking).
        public var isThinking: Bool
        public init(reasoning: String?, answer: String?, isThinking: Bool) {
            self.reasoning = reasoning
            self.answer = answer
            self.isThinking = isThinking
        }
    }

    public static func parse(_ text: String) -> Result {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source.contains(openTag) || source.contains(closeTag) else {
            return Result(reasoning: nil, answer: source.isEmpty ? nil : source, isThinking: false)
        }

        // Reasoning starts after an explicit <think>, or at the very start when the model was primed
        // with <think> by its chat template (only a trailing </think> is present).
        let reasoningStart: String.Index
        if let openRange = source.range(of: openTag) {
            reasoningStart = openRange.upperBound
        } else {
            reasoningStart = source.startIndex
        }

        let afterOpen = source[reasoningStart...]
        if let closeRange = afterOpen.range(of: closeTag) {
            let reasoning = String(afterOpen[..<closeRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let answer = String(afterOpen[closeRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return Result(reasoning: reasoning.isEmpty ? nil : reasoning,
                          answer: answer.isEmpty ? nil : answer, isThinking: false)
        }

        // Still thinking — no close tag yet.
        let reasoning = String(afterOpen).trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(reasoning: reasoning.isEmpty ? nil : reasoning, answer: nil, isThinking: true)
    }

    /// A one-line collapsed summary for a reasoning chain, e.g. "▸ Reasoning · 42 lines · /think to expand".
    public static func collapsedSummary(_ reasoning: String, expandHint: String = "/think to expand") -> String {
        let lines = reasoning.split(whereSeparator: \.isNewline).count
        let words = reasoning.split(whereSeparator: { $0 == " " || $0.isNewline }).count
        return "▸ Reasoning · \(max(lines, 1)) line\(lines == 1 ? "" : "s"), ~\(words) words · \(expandHint)"
    }
}
