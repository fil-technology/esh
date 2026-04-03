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

            let label = "\(item.role.title)\(item.isStreaming ? " [streaming]" : "")"
            lines.append(label)

            let wrapped = wrap(item.text.isEmpty ? "…" : item.text, width: max(width - 2, 20))
            for line in wrapped {
                lines.append("  \(line)")
            }
        }

        return lines
    }

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
