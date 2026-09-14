import Foundation
import Darwin

struct InteractiveListPicker {
    struct Item {
        let title: String
        let detail: String?

        init(title: String, detail: String? = nil) {
            self.title = title
            self.detail = detail
        }
    }

    enum Result {
        case selected(Int)
        case secondary(Character, Int)
        case cancelled
    }

    func pick(
        title: String,
        subtitle: String? = nil,
        items: [Item],
        primaryHint: String = "Enter select",
        secondaryHints: [String] = [],
        secondaryKeys: Set<Character> = []
    ) -> Result {
        guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0, !items.isEmpty else {
            return .cancelled
        }

        let previous = enableRawMode()
        defer {
            restore(previous)
            Swift.print("\u{001B}[0m")
            fflush(stdout)
        }

        var selectedIndex = 0
        render(
            title: title,
            subtitle: subtitle,
            items: items,
            selectedIndex: selectedIndex,
            primaryHint: primaryHint,
            secondaryHints: secondaryHints
        )

        while let byte = readByte() {
            switch byte {
            case 13, 10:
                return .selected(selectedIndex)
            case 27:
                if let next = readByte(timeout: 10), next == 91, let direction = readByte(timeout: 10) {
                    switch direction {
                    case 65:
                        selectedIndex = max(selectedIndex - 1, 0)
                    case 66:
                        selectedIndex = min(selectedIndex + 1, items.count - 1)
                    default:
                        return .cancelled
                    }
                    render(
                        title: title,
                        subtitle: subtitle,
                        items: items,
                        selectedIndex: selectedIndex,
                        primaryHint: primaryHint,
                        secondaryHints: secondaryHints
                    )
                } else {
                    return .cancelled
                }
            case UInt8(ascii: "k"):
                selectedIndex = max(selectedIndex - 1, 0)
                render(
                    title: title,
                    subtitle: subtitle,
                    items: items,
                    selectedIndex: selectedIndex,
                    primaryHint: primaryHint,
                    secondaryHints: secondaryHints
                )
            case UInt8(ascii: "j"):
                selectedIndex = min(selectedIndex + 1, items.count - 1)
                render(
                    title: title,
                    subtitle: subtitle,
                    items: items,
                    selectedIndex: selectedIndex,
                    primaryHint: primaryHint,
                    secondaryHints: secondaryHints
                )
            case UInt8(ascii: "q"):
                return .cancelled
            case UInt8(ascii: "<"):
                return .cancelled
            default:
                guard let scalar = UnicodeScalar(Int(byte)) else { continue }
                let character = Character(scalar)
                if secondaryKeys.contains(character) {
                    return .secondary(character, selectedIndex)
                }
            }
        }

        return .cancelled
    }

    private func render(
        title: String,
        subtitle: String?,
        items: [Item],
        selectedIndex: Int,
        primaryHint: String,
        secondaryHints: [String]
    ) {
        let clear = "\u{001B}[2J\u{001B}[H"
        let width = terminalWidth()
        let innerWidth = max(width - 4, 30)
        var lines: [String] = title.components(separatedBy: "\n")
        if let subtitle, !subtitle.isEmpty {
            lines.append(TerminalUIStyle.dim + subtitle + TerminalUIStyle.reset)
        }
        lines.append("")
        lines.append(TerminalUIStyle.rule(width: width, left: "╭", right: "╮"))

        for (index, item) in items.enumerated() {
            let marker = index == selectedIndex ? "\(TerminalUIStyle.cyan)›\(TerminalUIStyle.reset)" : "\(TerminalUIStyle.faint)·\(TerminalUIStyle.reset)"
            let content = composeRow(
                marker: marker,
                title: item.title,
                detail: item.detail,
                width: innerWidth,
                isSelected: index == selectedIndex
            )
            if index == selectedIndex {
                lines.append("\(TerminalUIStyle.border)│ \(TerminalUIStyle.reset)\(TerminalUIStyle.selection)\(TerminalUIStyle.padVisible(content, to: innerWidth))\(TerminalUIStyle.reset)\(TerminalUIStyle.border) │\(TerminalUIStyle.reset)")
            } else {
                lines.append("\(TerminalUIStyle.border)│ \(TerminalUIStyle.reset)\(TerminalUIStyle.padVisible(content, to: innerWidth))\(TerminalUIStyle.border) │\(TerminalUIStyle.reset)")
            }
        }

        lines.append(TerminalUIStyle.rule(width: width, left: "╰", right: "╯"))
        var hints = [primaryHint]
        hints.append(contentsOf: secondaryHints)
        hints.append("↑/↓ move")
        hints.append("< back")
        hints.append("esc cancel")
        lines.append("")
        lines.append(TerminalUIStyle.faint + hints.joined(separator: "  •  ") + TerminalUIStyle.reset)

        Swift.print(clear + lines.joined(separator: "\n"), terminator: "")
        fflush(stdout)
    }

    private func composeRow(
        marker: String,
        title: String,
        detail: String?,
        width: Int,
        isSelected: Bool
    ) -> String {
        let normalizedTitle = title.replacingOccurrences(of: "\n", with: " ")
        let titleColor = isSelected ? TerminalUIStyle.ink : TerminalUIStyle.ink
        let detailColor = isSelected ? TerminalUIStyle.ink : TerminalUIStyle.slate
        let prefix = "\(marker) "
        guard let detail, !detail.isEmpty else {
            return prefix + TerminalUIStyle.truncateVisible("\(titleColor)\(normalizedTitle)", limit: max(width - 2, 8))
        }

        let normalizedDetail = detail.replacingOccurrences(of: "\n", with: " ")
        let separator = "   "
        let availableWidth = max(width - 2, 12)
        let titleWidth = max(Int(Double(availableWidth) * 0.4), 12)
        let detailWidth = max(availableWidth - titleWidth - separator.count, 10)
        let left = TerminalUIStyle.padVisible(
            TerminalUIStyle.truncateVisible("\(titleColor)\(normalizedTitle)", limit: titleWidth),
            to: titleWidth
        )
        let right = TerminalUIStyle.truncateVisible(
            "\(detailColor)\(normalizedDetail)",
            limit: detailWidth
        )
        return prefix + left + separator + right
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
