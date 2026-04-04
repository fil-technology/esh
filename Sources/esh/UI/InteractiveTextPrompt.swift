import Foundation
import Darwin

struct InteractiveTextPrompt {
    func capture(
        label: String,
        initialValue: String = "",
        footer: String = "Enter submit • esc cancel • backspace edit"
    ) -> String? {
        guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
            print("\(label): ", terminator: "")
            fflush(stdout)
            return readLine()
        }

        let previous = enableRawMode()
        defer {
            restore(previous)
            Swift.print("\u{001B}[0m")
            fflush(stdout)
        }

        var value = initialValue
        render(label: label, value: value, footer: footer)

        while let byte = readByte() {
            switch byte {
            case 13, 10:
                Swift.print("")
                return value
            case 27:
                return nil
            case 127, 8:
                if !value.isEmpty {
                    value.removeLast()
                }
            default:
                guard let scalar = UnicodeScalar(Int(byte)), scalar.value >= 32 else {
                    continue
                }
                value.append(Character(scalar))
            }
            render(label: label, value: value, footer: footer)
        }

        return nil
    }

    private func render(label: String, value: String, footer: String) {
        Swift.print("\r\u{001B}[2K\(label): \(value)", terminator: "")
        fflush(stdout)
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

    private func readByte() -> UInt8? {
        var byte: UInt8 = 0
        let count = Darwin.read(STDIN_FILENO, &byte, 1)
        return count == 1 ? byte : nil
    }
}
