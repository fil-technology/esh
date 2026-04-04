import Foundation
import Darwin

struct InteractiveChoicePrompt {
    struct Choice {
        let key: Character
        let label: String
    }

    func choose(
        title: String,
        message: String,
        details: [String] = [],
        choices: [Choice],
        selectedIndex: Int = 0,
        footer: String = "←/→ navigate • enter confirm • < back • esc cancel"
    ) -> Character? {
        guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0, !choices.isEmpty else {
            return nil
        }

        let previous = enableRawMode()
        defer {
            restore(previous)
            Swift.print("\u{001B}[0m")
            fflush(stdout)
        }

        var index = max(0, min(selectedIndex, choices.count - 1))
        render(title: title, message: message, details: details, choices: choices, selectedIndex: index, footer: footer)

        while let byte = readByte() {
            switch byte {
            case 13, 10:
                return choices[index].key
            case 9:
                index = (index + 1) % choices.count
            case 27:
                if let next = readByte(timeout: 10), next == 91, let direction = readByte(timeout: 10) {
                    switch direction {
                    case 67:
                        index = min(index + 1, choices.count - 1)
                    case 68:
                        index = max(index - 1, 0)
                    default:
                        return nil
                    }
                } else {
                    return nil
                }
            case UInt8(ascii: "h"):
                index = max(index - 1, 0)
            case UInt8(ascii: "l"):
                index = min(index + 1, choices.count - 1)
            case UInt8(ascii: "<"), UInt8(ascii: "q"):
                return nil
            default:
                if let scalar = UnicodeScalar(Int(byte)) {
                    let character = Character(scalar)
                    if let matched = choices.first(where: { $0.key == character }) {
                        return matched.key
                    }
                }
            }

            render(title: title, message: message, details: details, choices: choices, selectedIndex: index, footer: footer)
        }

        return nil
    }

    private func render(
        title: String,
        message: String,
        details: [String],
        choices: [Choice],
        selectedIndex: Int,
        footer: String
    ) {
        let width = terminalWidth()
        let panelWidth = max(min(width - 8, 76), 44)
        let clear = "\u{001B}[2J\u{001B}[H"

        var lines: [String] = []
        lines.append("")
        lines.append(centered(TerminalUIStyle.rule(width: panelWidth, left: "╭", right: "╮"), terminalWidth: width))
        lines.append(centered(panelLine(TerminalUIStyle.bold + TerminalUIStyle.ink + title + TerminalUIStyle.reset, width: panelWidth), terminalWidth: width))
        lines.append(centered(panelLine("", width: panelWidth), terminalWidth: width))

        for line in wrap(message, width: panelWidth - 6) {
            lines.append(centered(panelLine(TerminalUIStyle.ink + line + TerminalUIStyle.reset, width: panelWidth), terminalWidth: width))
        }

        if !details.isEmpty {
            lines.append(centered(panelLine("", width: panelWidth), terminalWidth: width))
            for detail in details {
                for wrapped in wrap(detail, width: panelWidth - 8) {
                    lines.append(centered(panelLine(TerminalUIStyle.slate + wrapped + TerminalUIStyle.reset, width: panelWidth), terminalWidth: width))
                }
            }
        }

        lines.append(centered(panelLine("", width: panelWidth), terminalWidth: width))
        lines.append(centered(choiceRow(choices: choices, selectedIndex: selectedIndex, width: panelWidth - 4), terminalWidth: width))
        lines.append(centered(panelLine("", width: panelWidth), terminalWidth: width))
        lines.append(centered(panelLine(TerminalUIStyle.faint + footer + TerminalUIStyle.reset, width: panelWidth), terminalWidth: width))
        lines.append(centered(TerminalUIStyle.rule(width: panelWidth, left: "╰", right: "╯"), terminalWidth: width))

        Swift.print(clear + lines.joined(separator: "\n"), terminator: "")
        fflush(stdout)
    }

    private func panelLine(_ content: String, width: Int) -> String {
        let inner = max(width - 4, 0)
        return "\(TerminalUIStyle.border)│ \(TerminalUIStyle.reset)\(TerminalUIStyle.padVisible(content, to: inner))\(TerminalUIStyle.border) │\(TerminalUIStyle.reset)"
    }

    private func panelLine(_ content: String, width: Int, terminalWidth: Int) -> String {
        centered(panelLine(content, width: width), terminalWidth: terminalWidth)
    }

    private func choiceRow(choices: [Choice], selectedIndex: Int, width: Int) -> String {
        let parts = choices.enumerated().map { index, choice in
            let label = " \(choice.label) "
            if index == selectedIndex {
                return TerminalUIStyle.selection + TerminalUIStyle.bold + TerminalUIStyle.ink + label + TerminalUIStyle.reset
            }
            return TerminalUIStyle.faint + label + TerminalUIStyle.reset
        }
        return TerminalUIStyle.padVisible(parts.joined(separator: "  "), to: width)
    }

    private func centered(_ value: String, terminalWidth: Int) -> String {
        let visible = TerminalUIStyle.visibleWidth(of: value)
        let left = max((terminalWidth - visible) / 2, 0)
        return String(repeating: " ", count: left) + value
    }

    private func wrap(_ value: String, width: Int) -> [String] {
        guard width > 0 else { return [value] }
        var result: [String] = []
        var current = ""
        for word in value.split(separator: " ", omittingEmptySubsequences: false) {
            let token = String(word)
            let candidate = current.isEmpty ? token : current + " " + token
            if candidate.count > width, !current.isEmpty {
                result.append(current)
                current = token
            } else {
                current = candidate
            }
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result.isEmpty ? [""] : result
    }

    private func terminalWidth() -> Int {
        var windowSize = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &windowSize) == 0, windowSize.ws_col > 0 {
            return Int(windowSize.ws_col)
        }
        return Int(ProcessInfo.processInfo.environment["COLUMNS"] ?? "") ?? 100
    }

    private func enableRawMode() -> termios? {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return nil }
        var raw = original
        raw.c_lflag &= ~UInt(ECHO | ICANON)
        raw.c_iflag &= ~UInt(IXON | ICRNL)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { return nil }
        return original
    }

    private func restore(_ original: termios?) {
        guard var original else { return }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
    }

    private func readByte(timeout: Int32? = nil) -> UInt8? {
        if let timeout {
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, timeout)
            if ready <= 0 {
                return nil
            }
        }

        var byte: UInt8 = 0
        let count = Darwin.read(STDIN_FILENO, &byte, 1)
        return count == 1 ? byte : nil
    }
}
