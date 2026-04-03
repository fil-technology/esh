import Foundation

enum InputBarView {
    static func render(state: ChatScreenState, width: Int) -> String {
        let line = "> \(state.inputText)"
        guard line.count > width else { return line }
        let index = line.index(line.startIndex, offsetBy: max(width - 1, 0))
        return String(line[..<index])
    }
}
