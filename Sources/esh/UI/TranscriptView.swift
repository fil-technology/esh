import Foundation
import EshCore

enum TranscriptView {
    static func renderedLines(items: [TranscriptItem], availableWidth: Int, reasoningExpanded: Bool = false) -> [String] {
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
                let segments = assistantSegments(for: item, reasoningExpanded: reasoningExpanded)
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

    private static func assistantSegments(for item: TranscriptItem, reasoningExpanded: Bool) -> [AssistantSegment] {
        let parsed = ThinkingParser.parse(item.text)
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
            // Live thinking is always shown so the user sees progress; a completed chain collapses to a
            // one-line summary unless expanded (/think).
            let live = item.isStreaming && parsed.answer == nil
            if !live && !reasoningExpanded {
                segments.append(
                    AssistantSegment(
                        label: "\(TerminalUIStyle.bold)\(TerminalUIStyle.amber)Reasoning\(TerminalUIStyle.reset)",
                        text: TerminalUIStyle.faint + ThinkingParser.collapsedSummary(reasoning) + TerminalUIStyle.reset,
                        prefix: ""
                    )
                )
            } else {
                let label = live
                    ? "\(TerminalUIStyle.bold)\(TerminalUIStyle.amber)Reasoning\(TerminalUIStyle.reset) \(TerminalUIStyle.amber)[live]\(TerminalUIStyle.reset)"
                    : "\(TerminalUIStyle.bold)\(TerminalUIStyle.amber)Reasoning\(TerminalUIStyle.reset) \(TerminalUIStyle.faint)(/think to collapse)\(TerminalUIStyle.reset)"
                segments.append(
                    AssistantSegment(label: label, text: reasoning, prefix: TerminalUIStyle.dim)
                )
            }
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
