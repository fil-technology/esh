import Foundation

enum TranscriptView {
    static func renderedLines(items: [TranscriptItem], availableWidth: Int) -> [String] {
        let width = max(availableWidth, 40)
        guard !items.isEmpty else {
            return [
                "\(TerminalUIStyle.ink)Welcome to Esh chat.\(TerminalUIStyle.reset)",
                "\(TerminalUIStyle.slate)Type a message below. Use /save to persist the session or /exit to leave.\(TerminalUIStyle.reset)"
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
                    let rendered = MarkdownTerminalRenderer.render(
                        segment.text.isEmpty ? "…" : segment.text,
                        width: max(width - 4, 20),
                        defaultTint: segment.prefix.isEmpty ? nil : segment.prefix
                    )
                    for line in rendered {
                        let tint = line.tint ?? segment.prefix
                        lines.append("  \(tint)│ \(line.text)\(TerminalUIStyle.reset)")
                    }
                }
            } else {
                let label = roleLabel(for: item)
                lines.append(label)

                let rendered = MarkdownTerminalRenderer.render(
                    item.text.isEmpty ? "…" : item.text,
                    width: max(width - 4, 20)
                )
                for line in rendered {
                    lines.append("  \(TerminalUIStyle.blue)│\(TerminalUIStyle.reset) \(line.text)")
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
                    label: "\(TerminalUIStyle.bold)\(TerminalUIStyle.violet)Assistant\(TerminalUIStyle.reset)\(item.isStreaming ? " \(TerminalUIStyle.amber)[live]\(TerminalUIStyle.reset)" : "")",
                    text: item.text.isEmpty ? "…" : item.text,
                    prefix: ""
                )
            ]
        }

        var segments: [AssistantSegment] = []
        if let reasoning = parsed.reasoning, !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let label = item.isStreaming && parsed.answer == nil
                ? "\(TerminalUIStyle.bold)\(TerminalUIStyle.amber)Reasoning\(TerminalUIStyle.reset) \(TerminalUIStyle.amber)[live]\(TerminalUIStyle.reset)"
                : "\(TerminalUIStyle.bold)\(TerminalUIStyle.amber)Reasoning\(TerminalUIStyle.reset)"
            segments.append(
                AssistantSegment(
                    label: label,
                    text: reasoning,
                    prefix: TerminalUIStyle.dim
                )
            )
        }
        if let answer = parsed.answer, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let label = item.isStreaming
                ? "\(TerminalUIStyle.bold)\(TerminalUIStyle.violet)Assistant\(TerminalUIStyle.reset) \(TerminalUIStyle.amber)[live]\(TerminalUIStyle.reset)"
                : "\(TerminalUIStyle.bold)\(TerminalUIStyle.violet)Assistant\(TerminalUIStyle.reset)"
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

    private static func roleLabel(for item: TranscriptItem) -> String {
        switch item.role {
        case .user:
            return "\(TerminalUIStyle.bold)\(TerminalUIStyle.cyan)You\(TerminalUIStyle.reset)\(item.isStreaming ? " \(TerminalUIStyle.amber)[live]\(TerminalUIStyle.reset)" : "")"
        case .assistant:
            return "\(TerminalUIStyle.bold)\(TerminalUIStyle.violet)Assistant\(TerminalUIStyle.reset)\(item.isStreaming ? " \(TerminalUIStyle.amber)[live]\(TerminalUIStyle.reset)" : "")"
        case .system:
            return "\(TerminalUIStyle.bold)\(TerminalUIStyle.slate)System\(TerminalUIStyle.reset)"
        }
    }
}
