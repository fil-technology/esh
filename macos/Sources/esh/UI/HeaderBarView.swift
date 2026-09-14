import Foundation

enum HeaderBarView {
    static func renderedLines(state: ChatScreenState, width: Int) -> [String] {
        let innerWidth = max(width - 4, 20)
        let title = "\(TerminalUIStyle.bold)\(TerminalUIStyle.cyan)ESH Chat\(TerminalUIStyle.reset)"
        let session = "\(TerminalUIStyle.ink)\(state.sessionName)\(TerminalUIStyle.reset)"
        let statusColor = state.statusText.contains("failed")
            ? TerminalUIStyle.red
            : (state.statusText.contains("streaming") ? TerminalUIStyle.amber : TerminalUIStyle.green)
        let status = "\(statusColor)\(state.statusText.uppercased())\(TerminalUIStyle.reset)"

        let left = "\(title)  \(TerminalUIStyle.faint)session\(TerminalUIStyle.reset) \(session)"
        let right = "\(TerminalUIStyle.faint)\(state.backendLabel.lowercased())\(TerminalUIStyle.reset)  \(status)"
        let top = join(left: left, right: right, width: innerWidth)

        let meta = [
            "\(TerminalUIStyle.faint)model\(TerminalUIStyle.reset) \(TerminalUIStyle.ink)\(state.modelLabel)\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.faint)cache\(TerminalUIStyle.reset) \(TerminalUIStyle.blue)\(state.cacheMode)\(TerminalUIStyle.reset)",
            state.autosaveEnabled
                ? "\(TerminalUIStyle.green)autosave on\(TerminalUIStyle.reset)"
                : "\(TerminalUIStyle.faint)autosave off\(TerminalUIStyle.reset)",
            state.openAIServerEnabled
                ? "\(TerminalUIStyle.green)openai \(state.openAIServerAddress ?? "on")\(TerminalUIStyle.reset)"
                : "\(TerminalUIStyle.faint)openai off\(TerminalUIStyle.reset)"
        ].joined(separator: "  \(TerminalUIStyle.faint)•\(TerminalUIStyle.reset)  ")

        return [
            TerminalUIStyle.border + "╭" + String(repeating: "─", count: innerWidth + 2) + "╮" + TerminalUIStyle.reset,
            "\(TerminalUIStyle.border)│ \(TerminalUIStyle.reset)\(TerminalUIStyle.padVisible(top, to: innerWidth))\(TerminalUIStyle.border) │\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.border)│ \(TerminalUIStyle.reset)\(TerminalUIStyle.padVisible(TerminalUIStyle.truncateVisible(meta, limit: innerWidth), to: innerWidth))\(TerminalUIStyle.border) │\(TerminalUIStyle.reset)",
            TerminalUIStyle.border + "╰" + String(repeating: "─", count: innerWidth + 2) + "╯" + TerminalUIStyle.reset
        ]
    }

    private static func join(left: String, right: String, width: Int) -> String {
        let leftWidth = TerminalUIStyle.visibleWidth(of: left)
        let rightWidth = TerminalUIStyle.visibleWidth(of: right)
        if leftWidth + 2 + rightWidth <= width {
            return left + String(repeating: " ", count: width - leftWidth - rightWidth) + right
        }
        return TerminalUIStyle.truncateVisible(left, limit: width)
    }
}
