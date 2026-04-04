import Foundation

enum StartupBanner {
    nonisolated(unsafe) private static var hasAnimated = false

    static func render(modelCount: Int, sessionCount: Int, cacheCount: Int) -> String {
        let art = artLines(highlightStep: nil)

        let card = [
            "\(TerminalUIStyle.dim)┌──────────────────────────────────────┐\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.dim)│\(TerminalUIStyle.reset) \(TerminalUIStyle.ink)Local-first LLM for Apple Silicon\(TerminalUIStyle.reset) \(TerminalUIStyle.dim)│\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.dim)│\(TerminalUIStyle.reset) \(TerminalUIStyle.slate)MLX • TurboQuant • Sessions\(TerminalUIStyle.reset)      \(TerminalUIStyle.dim)│\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.dim)│\(TerminalUIStyle.reset) \(TerminalUIStyle.green)models \(modelCount)\(TerminalUIStyle.reset)  \(TerminalUIStyle.amber)sessions \(sessionCount)\(TerminalUIStyle.reset)  \(TerminalUIStyle.blue)caches \(cacheCount)\(TerminalUIStyle.reset) \(TerminalUIStyle.dim)│\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.dim)└──────────────────────────────────────┘\(TerminalUIStyle.reset)"
        ]

        return ([""] + zip(art, card).map { "\($0)   \($1)" }).joined(separator: "\n")
    }

    static func animateIfNeeded(modelCount: Int, sessionCount: Int, cacheCount: Int) {
        guard !hasAnimated, isatty(STDOUT_FILENO) != 0 else { return }
        hasAnimated = true

        let steps = [0, 0, 1, 1, 2, 2, 1, nil] as [Int?]
        let renderedFrames = steps.map { step in
            animatedFrame(
                highlightStep: step,
                modelCount: modelCount,
                sessionCount: sessionCount,
                cacheCount: cacheCount
            )
        }

        for (index, frame) in renderedFrames.enumerated() {
            Swift.print("\u{001B}[2J\u{001B}[H" + frame, terminator: "")
            fflush(stdout)
            let isFinal = index == renderedFrames.count - 1
            usleep(isFinal ? 300_000 : 260_000)
        }
    }

    private static func animatedFrame(
        highlightStep: Int?,
        modelCount: Int,
        sessionCount: Int,
        cacheCount: Int
    ) -> String {
        let art = artLines(highlightStep: highlightStep)
        let card = [
            "\(TerminalUIStyle.dim)┌──────────────────────────────────────┐\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.dim)│\(TerminalUIStyle.reset) \(TerminalUIStyle.ink)Local-first LLM for Apple Silicon\(TerminalUIStyle.reset) \(TerminalUIStyle.dim)│\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.dim)│\(TerminalUIStyle.reset) \(TerminalUIStyle.slate)MLX • TurboQuant • Sessions\(TerminalUIStyle.reset)      \(TerminalUIStyle.dim)│\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.dim)│\(TerminalUIStyle.reset) \(TerminalUIStyle.green)models \(modelCount)\(TerminalUIStyle.reset)  \(TerminalUIStyle.amber)sessions \(sessionCount)\(TerminalUIStyle.reset)  \(TerminalUIStyle.blue)caches \(cacheCount)\(TerminalUIStyle.reset) \(TerminalUIStyle.dim)│\(TerminalUIStyle.reset)",
            "\(TerminalUIStyle.dim)└──────────────────────────────────────┘\(TerminalUIStyle.reset)"
        ]
        return ([""] + zip(art, card).map { "\($0)   \($1)" }).joined(separator: "\n")
    }

    private static func artLines(highlightStep: Int?) -> [String] {
        let normal: [String] = [TerminalUIStyle.pink, TerminalUIStyle.violet, TerminalUIStyle.blue]
        let glow: [String] = [TerminalUIStyle.amber, TerminalUIStyle.cyan, TerminalUIStyle.green]

        func color(_ index: Int) -> String {
            if highlightStep == index {
                return glow[index]
            }
            return normal[index]
        }

        return [
            "\(color(0))███████╗\(color(1))███████╗\(color(2))██╗  ██╗\(TerminalUIStyle.reset)",
            "\(color(0))██╔════╝\(color(1))██╔════╝\(color(2))██║  ██║\(TerminalUIStyle.reset)",
            "\(color(0))█████╗  \(color(1))███████╗\(color(2))███████║\(TerminalUIStyle.reset)",
            "\(color(0))██╔══╝  \(color(1))╚════██║\(color(2))██╔══██║\(TerminalUIStyle.reset)",
            "\(color(0))███████╗\(color(1))███████║\(color(2))██║  ██║\(TerminalUIStyle.reset)"
        ]
    }
}
