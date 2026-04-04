import Foundation

enum StartupBanner {
    static func render(modelCount: Int, sessionCount: Int, cacheCount: Int) -> String {
        [
            "\(TerminalUIStyle.border)╭──────────────────────────────────────────────────────────────────────╮\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.border)│ \(TerminalUIStyle.bold)\(TerminalUIStyle.cyan)ESH\(TerminalUIStyle.reset)  \(TerminalUIStyle.faint)Local-first LLM workspace for Apple Silicon\(TerminalUIStyle.reset)                 \(TerminalUIStyle.border)│\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.border)│ \(TerminalUIStyle.pink)models \(modelCount)\(TerminalUIStyle.reset)  \(TerminalUIStyle.violet)sessions \(sessionCount)\(TerminalUIStyle.reset)  \(TerminalUIStyle.blue)caches \(cacheCount)\(TerminalUIStyle.reset)  \(TerminalUIStyle.faint)MLX • TurboQuant • Chat • Cache\(TerminalUIStyle.reset) \(TerminalUIStyle.border)│\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.border)╰──────────────────────────────────────────────────────────────────────╯\(TerminalUIStyle.reset)"
        ].joined(separator: "\n")
    }
}
