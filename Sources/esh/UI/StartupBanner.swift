import Foundation

enum StartupBanner {
    nonisolated(unsafe) private static var hasAnimated = false

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

    static func animateIfNeeded(modelCount: Int, sessionCount: Int, cacheCount: Int) {
        guard !hasAnimated, isatty(STDOUT_FILENO) != 0 else { return }
        hasAnimated = true

        let frames = [0.35, 0.65, 1.0].map { progress in
            animatedFrame(
                progress: progress,
                modelCount: modelCount,
                sessionCount: sessionCount,
                cacheCount: cacheCount
            )
        }

        for frame in frames {
            Swift.print("\u{001B}[2J\u{001B}[H" + frame, terminator: "")
            fflush(stdout)
            usleep(90_000)
        }
    }

    private static func animatedFrame(
        progress: Double,
        modelCount: Int,
        sessionCount: Int,
        cacheCount: Int
    ) -> String {
        let lines = render(modelCount: modelCount, sessionCount: sessionCount, cacheCount: cacheCount)
            .components(separatedBy: "\n")
        return lines.enumerated().map { index, line in
            let visibleCount = max(Int(Double(TerminalUIStyle.stripANSI(from: line).count) * progress), min(index + 2, 8))
            return TerminalUIStyle.truncateVisible(line, limit: max(visibleCount, 1))
        }.joined(separator: "\n")
    }
}
