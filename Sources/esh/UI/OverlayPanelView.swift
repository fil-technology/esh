import Foundation

enum OverlayPanelView {
    static func renderedLines(overlay: OverlayPanelState, availableWidth: Int) -> [String] {
        let width = max(availableWidth, 40)
        let innerWidth = max(width - 4, 20)
        let horizontal = "+" + String(repeating: "-", count: max(width - 2, 1)) + "+"

        var lines: [String] = [horizontal]
        lines.append(boxed(" \(overlay.title)", width: innerWidth))
        lines.append(boxed("", width: innerWidth))

        for line in overlay.lines {
            for wrapped in wrap(line, width: innerWidth) {
                lines.append(boxed(wrapped, width: innerWidth))
            }
        }

        lines.append(horizontal)
        return lines
    }

    private static func boxed(_ text: String, width: Int) -> String {
        let clipped = text.count > width ? String(text.prefix(width)) : text
        return "| " + clipped.padding(toLength: width, withPad: " ", startingAt: 0) + " |"
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
