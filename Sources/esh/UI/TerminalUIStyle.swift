import Foundation

enum TerminalUIStyle {
    static let reset = "\u{001B}[0m"
    static let bold = "\u{001B}[1m"
    static let dim = "\u{001B}[38;5;245m"
    static let faint = "\u{001B}[38;5;240m"
    static let ink = rgb(230, 236, 245)
    static let slate = rgb(150, 163, 184)
    static let border = rgb(77, 90, 132)
    static let blue = rgb(116, 167, 255)
    static let cyan = rgb(107, 214, 255)
    static let violet = rgb(184, 142, 255)
    static let pink = rgb(255, 135, 182)
    static let green = rgb(130, 223, 166)
    static let amber = rgb(255, 211, 105)
    static let red = rgb(255, 120, 120)
    static let selection = "\u{001B}[48;2;34;47;87m"

    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> String {
        "\u{001B}[38;2;\(r);\(g);\(b)m"
    }

    static func stripANSI(from value: String) -> String {
        value.replacingOccurrences(
            of: #"\u{001B}\[[0-9;]*m|\u{001B}\[[0-9;]*[A-Za-z]"#,
            with: "",
            options: .regularExpression
        )
    }

    static func visibleWidth(of value: String) -> Int {
        stripANSI(from: value).count
    }

    static func truncateVisible(_ value: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        let plain = stripANSI(from: value)
        guard plain.count > limit else { return value }
        let index = plain.index(plain.startIndex, offsetBy: max(limit - 1, 0))
        return String(plain[..<index]) + "…"
    }

    static func padVisible(_ value: String, to width: Int) -> String {
        let visible = visibleWidth(of: value)
        guard visible < width else { return value }
        return value + String(repeating: " ", count: width - visible)
    }

    static func rule(width: Int, left: String = "├", fill: String = "─", right: String = "┤") -> String {
        guard width >= 2 else { return String(repeating: fill, count: max(width, 0)) }
        return border + left + String(repeating: fill, count: width - 2) + right + reset
    }
}
