import Foundation

enum StartupBanner {
    static func render(modelCount: Int, sessionCount: Int, cacheCount: Int) -> String {
        let art = [
            "\(TerminalUIStyle.pink)███████╗\(TerminalUIStyle.violet)███████╗\(TerminalUIStyle.blue)██╗  ██╗\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.pink)██╔════╝\(TerminalUIStyle.violet)██╔════╝\(TerminalUIStyle.blue)██║  ██║\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.pink)█████╗  \(TerminalUIStyle.violet)███████╗\(TerminalUIStyle.blue)███████║\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.pink)██╔══╝  \(TerminalUIStyle.violet)╚════██║\(TerminalUIStyle.blue)██╔══██║\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.pink)███████╗\(TerminalUIStyle.violet)███████║\(TerminalUIStyle.blue)██║  ██║\(TerminalUIStyle.reset)"
        ]

        let card = [
            "\(TerminalUIStyle.dim)┌──────────────────────────────────────┐\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.dim)│\(TerminalUIStyle.reset) \(TerminalUIStyle.ink)Local-first LLM for Apple Silicon\(TerminalUIStyle.reset) \(TerminalUIStyle.dim)│\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.dim)│\(TerminalUIStyle.reset) \(TerminalUIStyle.slate)MLX • TurboQuant • Sessions\(TerminalUIStyle.reset)      \(TerminalUIStyle.dim)│\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.dim)│\(TerminalUIStyle.reset) \(TerminalUIStyle.green)models \(modelCount)\(TerminalUIStyle.reset)  \(TerminalUIStyle.amber)sessions \(sessionCount)\(TerminalUIStyle.reset)  \(TerminalUIStyle.blue)caches \(cacheCount)\(TerminalUIStyle.reset) \(TerminalUIStyle.dim)│\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.dim)└──────────────────────────────────────┘\(TerminalUIStyle.reset)"
        ]

        return zip(art, card).map { "\($0)   \($1)" }.joined(separator: "\n")
    }
}
