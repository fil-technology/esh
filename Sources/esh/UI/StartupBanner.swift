import Foundation

enum StartupBanner {
    static func render(modelCount: Int, sessionCount: Int, cacheCount: Int) -> String {
        let art = [
            "\(rgb(255, 112, 166))███████╗\(rgb(159, 122, 234))███████╗\(rgb(88, 196, 255))██╗  ██╗\(reset)",
            "\(rgb(255, 112, 166))██╔════╝\(rgb(159, 122, 234))██╔════╝\(rgb(88, 196, 255))██║  ██║\(reset)",
            "\(rgb(255, 112, 166))█████╗  \(rgb(159, 122, 234))███████╗\(rgb(88, 196, 255))███████║\(reset)",
            "\(rgb(255, 112, 166))██╔══╝  \(rgb(159, 122, 234))╚════██║\(rgb(88, 196, 255))██╔══██║\(reset)",
            "\(rgb(255, 112, 166))███████╗\(rgb(159, 122, 234))███████║\(rgb(88, 196, 255))██║  ██║\(reset)"
        ]

        let card = [
            "\(dim)┌──────────────────────────────────────┐\(reset)",
            "\(dim)│\(reset) \(rgb(230, 236, 245))Local-first LLM for Apple Silicon\(reset) \(dim)│\(reset)",
            "\(dim)│\(reset) \(rgb(170, 178, 191))MLX • TurboQuant • Sessions\(reset)      \(dim)│\(reset)",
            "\(dim)│\(reset) \(rgb(130, 223, 166))models \(modelCount)\(reset)  \(rgb(255, 211, 105))sessions \(sessionCount)\(reset)  \(rgb(88, 196, 255))caches \(cacheCount)\(reset) \(dim)│\(reset)",
            "\(dim)└──────────────────────────────────────┘\(reset)"
        ]

        return zip(art, card).map { "\($0)   \($1)" }.joined(separator: "\n")
    }

    private static let reset = "\u{001B}[0m"
    private static let dim = "\u{001B}[38;5;245m"

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> String {
        "\u{001B}[38;2;\(r);\(g);\(b)m"
    }
}
