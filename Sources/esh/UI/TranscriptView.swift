import Foundation

enum TranscriptView {
    static func renderedLines(items: [TranscriptItem], availableWidth: Int) -> [String] {
        let width = max(availableWidth, 40)
        guard !items.isEmpty else {
            return [
                "Welcome to Esh chat.",
                "Type a message below. Use /save to persist the session or /exit to leave."
            ]
        }

        var lines: [String] = []
        for (index, item) in items.enumerated() {
            if index > 0 {
                lines.append("")
            }

            if item.role == .assistant {
                let segments = assistantSegments(for: item)
                for (segmentIndex, segment) in segments.enumerated() {
                    if segmentIndex > 0 {
                        lines.append("")
                    }
                    lines.append(segment.label)
                    let wrapped = wrap(segment.text.isEmpty ? "…" : segment.text, width: max(width - 2, 20))
                    for line in wrapped {
                        lines.append("  \(segment.prefix)\(line)\(reset)")
                    }
                }
            } else {
                let label = "\(item.role.title)\(item.isStreaming ? " [streaming]" : "")"
                lines.append(label)

                let wrapped = wrap(item.text.isEmpty ? "…" : item.text, width: max(width - 2, 20))
                for line in wrapped {
                    lines.append("  \(line)")
                }
            }
        }

        return lines
    }

    private struct AssistantSegment {
        let label: String
        let text: String
        let prefix: String
    }

    private static func assistantSegments(for item: TranscriptItem) -> [AssistantSegment] {
        let parsed = parseThinkingSegments(from: item.text)
        if parsed.reasoning == nil && parsed.answer == nil {
            return [
                AssistantSegment(
                    label: "Assistant\(item.isStreaming ? " [streaming]" : "")",
                    text: item.text.isEmpty ? "…" : item.text,
                    prefix: ""
                )
            ]
        }

        var segments: [AssistantSegment] = []
        if let reasoning = parsed.reasoning, !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let label = item.isStreaming && parsed.answer == nil
                ? "Assistant Reasoning [streaming]"
                : "Assistant Reasoning"
            segments.append(
                AssistantSegment(
                    label: label,
                    text: reasoning,
                    prefix: dim
                )
            )
        }
        if let answer = parsed.answer, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let label = item.isStreaming ? "Assistant [streaming]" : "Assistant"
            segments.append(
                AssistantSegment(
                    label: label,
                    text: answer,
                    prefix: ""
                )
            )
        }
        return segments
    }

    private static func parseThinkingSegments(from text: String) -> (reasoning: String?, answer: String?) {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source.contains("<think>") || source.contains("</think>") else {
            return (nil, source.isEmpty ? nil : source)
        }

        let openTag = "<think>"
        let closeTag = "</think>"
        guard let openRange = source.range(of: openTag) else {
            return (nil, source)
        }

        let afterOpen = source[openRange.upperBound...]
        if let closeRange = afterOpen.range(of: closeTag) {
            let reasoning = String(afterOpen[..<closeRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let answer = String(afterOpen[closeRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (reasoning.isEmpty ? nil : reasoning, answer.isEmpty ? nil : answer)
        }

        let reasoning = String(afterOpen).trimmingCharacters(in: .whitespacesAndNewlines)
        return (reasoning.isEmpty ? nil : reasoning, nil)
    }

    private static let reset = "\u{001B}[0m"
    private static let dim = "\u{001B}[38;5;245m"

    private static func wrap(_ text: String, width: Int) -> [String] {
        guard !text.isEmpty else { return [""] }

        var result: [String] = []
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let source = paragraph.isEmpty ? "" : String(paragraph)
            if source.isEmpty {
                result.append("")
                continue
            }

            var current = ""
            for word in source.split(separator: " ", omittingEmptySubsequences: false) {
                let token = String(word)
                if current.isEmpty {
                    current = token
                } else if current.count + 1 + token.count <= width {
                    current += " " + token
                } else {
                    result.append(current)
                    current = token
                }
            }
            if !current.isEmpty {
                result.append(current)
            }
        }

        return result
    }
}
