import Foundation

/// The catalog of chat slash commands, with descriptions and prefix-based suggestions — so the
/// Terminal UX can autocomplete as the user types `/…`. Pure and testable; the TUI renders the result.
public enum SlashCommandCatalog {
    public struct Entry: Equatable, Sendable {
        public let command: String       // e.g. "/model"
        public let argHint: String?      // e.g. "<id>"
        public let description: String
        public init(command: String, argHint: String? = nil, description: String) {
            self.command = command
            self.argHint = argHint
            self.description = description
        }
        public var display: String { argHint.map { "\(command) \($0)" } ?? command }
    }

    public static let all: [Entry] = [
        .init(command: "/model", argHint: "[id]", description: "Show or switch the active model"),
        .init(command: "/use-model", argHint: "<id-or-repo>", description: "Switch to an installed model"),
        .init(command: "/models", description: "List installed models"),
        .init(command: "/auto", description: "What the Adaptive Scheduler would pick"),
        .init(command: "/status", description: "Runtime / backend / cache / context status"),
        .init(command: "/context", description: "Context usage (last turn)"),
        .init(command: "/performance", description: "Last-turn latency / tokens / tok-s"),
        .init(command: "/think", description: "Expand or collapse model reasoning"),
        .init(command: "/settings", description: "Show current chat settings"),
        .init(command: "/new", argHint: "[name]", description: "Start a new session"),
        .init(command: "/switch", argHint: "<name-or-uuid>", description: "Switch session"),
        .init(command: "/sessions", description: "List saved sessions"),
        .init(command: "/cache", argHint: "raw|turbo|triattention|auto", description: "Set the cache mode"),
        .init(command: "/intent", argHint: "chat|code|documentqa|agentrun|multimodal", description: "Set the session intent"),
        .init(command: "/serve", argHint: "toggle|start|stop|status", description: "OpenAI-compatible server"),
        .init(command: "/search", argHint: "<text>", description: "Search the active session"),
        .init(command: "/plan", argHint: "<task>", description: "Build a local context brief"),
        .init(command: "/doctor", description: "Environment / runtime health"),
        .init(command: "/clear", description: "Clear the transcript"),
        .init(command: "/menu", description: "Show the full command menu"),
        .init(command: "/exit", description: "Leave chat")
    ]

    /// Suggestions for the current input. Returns [] when the input isn't a lone slash-command token
    /// (e.g. it has a space — the command is complete — or doesn't start with `/`).
    public static func suggestions(for input: String, limit: Int = 6) -> [Entry] {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/"), !trimmed.contains(" ") else { return [] }
        let needle = trimmed.lowercased()
        if needle == "/" { return Array(all.prefix(limit)) }
        let matches = all.filter { $0.command.lowercased().hasPrefix(needle) }
        return Array(matches.prefix(limit))
    }
}
