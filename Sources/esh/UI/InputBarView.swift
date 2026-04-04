import Foundation

enum InputBarView {
    static func render(state: ChatScreenState, width: Int) -> String {
        let prefix = "\(TerminalUIStyle.bold)\(TerminalUIStyle.cyan)prompt\(TerminalUIStyle.reset) \(TerminalUIStyle.faint)>\(TerminalUIStyle.reset) "
        let line = prefix + state.inputText
        return TerminalUIStyle.truncateVisible(line, limit: width)
    }
}
