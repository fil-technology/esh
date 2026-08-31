import Foundation

/// The single canonical streaming event model for esh inference (M8). Every streaming surface — serve,
/// Web Chat, Terminal UX — consumes this envelope; backend/adapter specifics are hidden. Producers
/// emit only events they can genuinely observe: today's local runtimes stream visible text, so the
/// text adapter emits `.textDelta` + a terminal `.done`/`.failed`. `reasoningDelta`, `toolCall`, and
/// `usage` events exist for producers/adapters that can supply them and are NEVER fabricated.
public enum EshStreamEvent: Sendable, Equatable {
    /// Incremental assistant-visible text.
    case textDelta(String)
    /// Incremental reasoning/thinking text — only from producers that separate it from visible text.
    case reasoningDelta(String)
    /// A tool/function call the model requested.
    case toolCall(EshToolCall)
    /// Final normalized usage accounting (only measured counters).
    case usage(EshUsage)
    /// Terminal success event with an optional finish reason (e.g. "stop", "length").
    case done(finishReason: String?)
    /// Terminal failure event carrying a human-readable message.
    case failed(message: String)

    /// True for the two terminal events (`.done` / `.failed`).
    public var isTerminal: Bool {
        switch self {
        case .done, .failed: return true
        default: return false
        }
    }
}

public extension Sequence where Element == EshStreamEvent {
    /// Concatenate the visible text deltas from a collected event stream (used by buffered callers).
    func collectedText() -> String {
        reduce(into: "") { acc, event in
            if case let .textDelta(text) = event { acc += text }
        }
    }
}
