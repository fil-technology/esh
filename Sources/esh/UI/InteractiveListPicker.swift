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
            Swift.print("\u{001B}[0m", terminator: "")
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
        var lines: [String] = [title]
        if let subtitle, !subtitle.isEmpty {
            lines.append(subtitle)
        }
        lines.append("")

        for (index, item) in items.enumerated() {
            let marker = index == selectedIndex ? "›" : " "
            let content = composeRow(
                marker: marker,
                title: item.title,
                detail: item.detail,
                width: width
            )
            if index == selectedIndex {
                lines.append("\u{001B}[4;1;97;48;5;24m\(content)\u{001B}[0m")
            } else {
                lines.append(content)
            }
        }

        lines.append("")
        var hints = [primaryHint]
        hints.append(contentsOf: secondaryHints)
        hints.append("↑/↓ move")
        hints.append("q back")
        lines.append(hints.joined(separator: " | "))

        Swift.print(clear + lines.joined(separator: "\n"), terminator: "")
        fflush(stdout)
    }

    private func composeRow(marker: String, title: String, detail: String?, width: Int) -> String {
        let normalizedTitle = title.replacingOccurrences(of: "\n", with: " ")
        let prefix = "\(marker) "
        guard let detail, !detail.isEmpty else {
            return prefix + truncate(normalizedTitle, limit: max(width - prefix.count, 8))
        }

        let normalizedDetail = detail.replacingOccurrences(of: "\n", with: " ")
        let detailWidth = min(max(width / 3, 18), 42)
        let titleWidth = max(width - prefix.count - detailWidth - 2, 12)
        let left = pad(truncate(normalizedTitle, limit: titleWidth), width: titleWidth)
        let right = truncate(normalizedDetail, limit: detailWidth)
        let spacer = String(repeating: " ", count: max(width - prefix.count - visibleCount(left) - visibleCount(right), 2))
        return prefix + left + spacer + "\u{001B}[38;5;245m\(right)\u{001B}[0m"
    }

    private func truncate(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        guard limit > 1 else { return String(value.prefix(limit)) }
        return String(value.prefix(limit - 1)) + "…"
    }

    private func pad(_ value: String, width: Int) -> String {
        if value.count >= width { return value }
        return value + String(repeating: " ", count: width - value.count)
    }

    private func visibleCount(_ value: String) -> Int {
        value.count
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
