import Foundation

/// Pure, testable formatting for the first-class Terminal UX status line and per-turn execution
/// summary. Kept in EshCore (not the TUI executable) so the formatting logic is unit-tested; the TUI
/// only styles/positions the strings these produce.
public enum TerminalStatusFormatting {

    /// The compact per-turn summary shown after a response completes, e.g.
    /// `1.8s · 927 tokens · 38 tok/s · KV hit`. Only includes fields the runtime actually reported.
    public static func executionSummary(metrics: Metrics, latencySeconds: Double?) -> String {
        var parts: [String] = []
        if let latency = latencySeconds {
            parts.append(String(format: "%.1fs", latency))
        }
        if let out = metrics.generationTokens {
            let inTok = metrics.promptTokens
            parts.append(inTok != nil ? "\(inTok! + out) tokens (\(inTok!)+\(out))" : "\(out) tokens")
        }
        if let tps = metrics.tokensPerSecond {
            parts.append(String(format: "%.0f tok/s", tps))
        }
        if let hit = metrics.cacheHit {
            parts.append(hit ? "KV hit" : "KV miss")
        }
        if let mem = metrics.memoryBytes {
            parts.append(ByteFormatting.string(for: mem))
        }
        return parts.joined(separator: " · ")
    }

    /// A one-line residency/context/memory summary for the header, e.g.
    /// `weights resident · 12K/32K ctx · 18.4 GB`. Fields omitted when unknown.
    public static func residencyLine(residency: RuntimeResidency?, contextUsed: Int?, contextLimit: Int?, memoryBytes: Int64?) -> String {
        var parts: [String] = []
        if let residency {
            parts.append(residency == .weightsResident ? "weights resident" : "handle cached")
        }
        if let used = contextUsed {
            let limit = contextLimit.map { "/\(compactTokens($0))" } ?? ""
            parts.append("\(compactTokens(used))\(limit) ctx")
        }
        if let mem = memoryBytes {
            parts.append(ByteFormatting.string(for: mem))
        }
        return parts.joined(separator: " · ")
    }

    /// Human-compact token counts: 12000 -> "12K", 512 -> "512".
    public static func compactTokens(_ n: Int) -> String {
        if n >= 1000 { return "\(Int((Double(n) / 1000).rounded()))K" }
        return "\(n)"
    }
}

/// The canonical first-class Terminal UX slash commands (mockup set). Parsing is pure and testable;
/// the TUI dispatches on the parsed value.
public enum SlashCommand: Equatable, Sendable {
    case model(String?)        // /model [id]  — show or switch
    case auto                  // /auto        — scheduler-driven model selection
    case new                   // /new         — new session
    case sessions              // /sessions    — list sessions
    case status                // /status      — runtime/backend/residency/cache
    case context               // /context     — context usage
    case performance           // /performance — last-turn perf
    case settings              // /settings
    case doctor                // /doctor
    case clear                 // /clear       — clear transcript
    case help                  // /help, /menu
    case exit                  // /exit, /quit
    case other(String)         // any other /command (handled elsewhere)

    /// Parse a raw input line. Returns nil for non-slash input (a normal chat message).
    public static func parse(_ raw: String) -> SlashCommand? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") else { return nil }
        let parts = trimmed.dropFirst().split(separator: " ", maxSplits: 1)
        let verb = parts.first.map(String.init)?.lowercased() ?? ""
        let arg = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : nil
        switch verb {
        case "model": return .model(arg?.isEmpty == false ? arg : nil)
        case "auto": return .auto
        case "new": return .new
        case "sessions": return .sessions
        case "status": return .status
        case "context": return .context
        case "performance", "perf": return .performance
        case "settings": return .settings
        case "doctor": return .doctor
        case "clear": return .clear
        case "help", "menu": return .help
        case "exit", "quit": return .exit
        default: return .other(trimmed)
        }
    }
}
