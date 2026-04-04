import Foundation

enum OverlayPanelView {
    static func renderedLines(overlay: OverlayPanelState, availableWidth: Int) -> [String] {
        let width = max(min(Int(Double(availableWidth) * 0.76), availableWidth - 4), 40)
        let innerWidth = max(width - 4, 20)
        let horizontal = TerminalUIStyle.border + "╭" + String(repeating: "─", count: max(width - 2, 1)) + "╮" + TerminalUIStyle.reset

        var lines: [String] = [horizontal]
        lines.append(boxed("\(TerminalUIStyle.bold)\(TerminalUIStyle.cyan)\(overlay.title)\(TerminalUIStyle.reset)", width: innerWidth))
        lines.append(boxed("", width: innerWidth))

        for line in overlay.lines {
            for wrapped in wrap(line, width: innerWidth) {
                lines.append(boxed(wrapped, width: innerWidth))
            }
        }

        lines.append(TerminalUIStyle.border + "╰" + String(repeating: "─", count: max(width - 2, 1)) + "╯" + TerminalUIStyle.reset)
        return lines
    }

    private static func boxed(_ text: String, width: Int) -> String {
        let clipped = TerminalUIStyle.truncateVisible(text, limit: width)
        return "\(TerminalUIStyle.border)│ \(TerminalUIStyle.reset)" + TerminalUIStyle.padVisible(clipped, to: width) + "\(TerminalUIStyle.border) │\(TerminalUIStyle.reset)"
    }

    private static func wrap(_ text: String, width: Int) -> [String] {
        guard !text.isEmpty else { return [""] }
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            let token = String(word)
            if current.isEmpty {
                current = token
            } else if current.count + 1 + token.count <= width {
                current += " " + token
            } else {
                lines.append(current)
                current = token
            }
        }
        if !current.isEmpty {
            lines.append(current)
        }
        return lines
    }
}
