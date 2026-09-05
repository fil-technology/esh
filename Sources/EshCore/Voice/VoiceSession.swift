import Foundation

// esh 2.1 — Voice 2.1 / Conversational Voice Runtime (canonical, server-owned session core).
//
// This is the typed runtime the milestone defines: a bounded VoiceSession with an explicit state machine,
// a bounded conversation context, endpoint/interruption policies, and per-turn latency metrics. It is
// transport- and hardware-agnostic on purpose — the orchestrator (VoiceSessionOrchestrator) drives it from
// injected STT/inference/TTS/endpointing collaborators, so the same core serves the browser loop today and a
// future duplex transport later. Web/client state is NOT canonical runtime state; this type is.

/// Canonical runtime states for one voice session (spec §3).
public enum VoiceSessionState: String, Sendable, Codable, CaseIterable {
    case idle              // created, not yet listening
    case listening         // mic open, waiting for speech
    case speechDetected    // VAD saw speech start
    case transcribing      // endpoint reached, running STT
    case thinking          // LLM producing a reply
    case speaking          // TTS playing back
    case interrupted       // user barged in; tearing down the current turn
    case error             // recoverable error surfaced this turn
    case ended             // session closed; terminal
}

public typealias VoiceSessionID = String

public enum VoiceRole: String, Sendable, Codable {
    case user
    case assistant
}

/// One completed conversational turn (kept in the bounded context).
public struct VoiceTurn: Sendable, Codable, Equatable {
    public var role: VoiceRole
    public var text: String
    public init(role: VoiceRole, text: String) {
        self.role = role
        self.text = text
    }
}

/// Bounded current-session history (spec §11). This is conversation working-memory ONLY — it is capped, it is
/// reset/ended explicitly, and it must never become durable personal semantic memory (that is Ashex's concern).
public struct VoiceConversationContext: Sendable, Codable, Equatable {
    public private(set) var turns: [VoiceTurn]
    public let maxTurns: Int
    public let maxCharacters: Int

    public init(maxTurns: Int = 20, maxCharacters: Int = 8000) {
        self.turns = []
        self.maxTurns = max(1, maxTurns)
        self.maxCharacters = max(200, maxCharacters)
    }

    /// Append a turn and enforce both bounds (drop oldest turns first). Empty text is ignored.
    public mutating func append(_ turn: VoiceTurn) {
        let trimmed = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        turns.append(VoiceTurn(role: turn.role, text: trimmed))
        while turns.count > maxTurns { turns.removeFirst() }
        while totalCharacters > maxCharacters, turns.count > 1 { turns.removeFirst() }
    }

    public var totalCharacters: Int { turns.reduce(0) { $0 + $1.text.count } }

    /// Clear all turns (spec §11 explicit reset).
    public mutating func reset() { turns.removeAll() }
}

/// How the runtime decides a user has stopped speaking (spec §5). Acoustic baseline first; semantic later.
public struct VoiceEndpointPolicy: Sendable, Codable, Equatable {
    /// Trailing silence that ends a turn once speech has been detected.
    public var trailingSilenceMs: Int
    /// Hard cap on a single listen window (safety).
    public var maxUtteranceMs: Int
    /// RMS energy above which a frame counts as speech (acoustic baseline).
    public var speechEnergyThreshold: Double

    public init(trailingSilenceMs: Int = 1400, maxUtteranceMs: Int = 30_000, speechEnergyThreshold: Double = 0.045) {
        self.trailingSilenceMs = max(200, trailingSilenceMs)
        self.maxUtteranceMs = max(1000, maxUtteranceMs)
        self.speechEnergyThreshold = speechEnergyThreshold
    }
}

/// How the runtime handles the user speaking while the assistant is talking (spec §9 barge-in).
public struct VoiceInterruptionPolicy: Sendable, Codable, Equatable {
    /// Whether genuine user speech during `speaking`/`thinking` cancels the current turn.
    public var bargeInEnabled: Bool
    /// Minimum detected speech before we treat it as a real interruption (guards against echo/blips).
    public var minBargeInMs: Int

    public init(bargeInEnabled: Bool = true, minBargeInMs: Int = 250) {
        self.bargeInEnabled = bargeInEnabled
        self.minBargeInMs = max(0, minBargeInMs)
    }
}

/// Static configuration for a session. Model/language pins are honored downstream; nil = Auto (Scheduler).
public struct VoiceSessionConfig: Sendable, Codable, Equatable {
    public var endpoint: VoiceEndpointPolicy
    public var interruption: VoiceInterruptionPolicy
    public var maxContextTurns: Int
    public var maxContextCharacters: Int
    /// Explicit language pin (BCP-47-ish, e.g. "en", "ru", "he") or nil for auto/provider default.
    public var language: String?
    /// Explicit model pins, or nil for Auto (the Scheduler chooses HOW).
    public var sttModel: String?
    public var inferenceModel: String?
    public var ttsModel: String?

    public init(endpoint: VoiceEndpointPolicy = .init(),
                interruption: VoiceInterruptionPolicy = .init(),
                maxContextTurns: Int = 20, maxContextCharacters: Int = 8000,
                language: String? = nil, sttModel: String? = nil,
                inferenceModel: String? = nil, ttsModel: String? = nil) {
        self.endpoint = endpoint
        self.interruption = interruption
        self.maxContextTurns = maxContextTurns
        self.maxContextCharacters = maxContextCharacters
        self.language = language
        self.sttModel = sttModel
        self.inferenceModel = inferenceModel
        self.ttsModel = ttsModel
    }
}

/// Latency budget for one turn (spec §14). Timestamps are monotonic seconds (ProcessInfo.systemUptime);
/// nil means the phase did not occur (e.g. a turn cancelled by barge-in never reaches firstAudible).
public struct VoiceTurnMetrics: Sendable, Codable, Equatable {
    public var speechEndedAt: Double?
    public var finalTranscriptAt: Double?
    public var firstTokenAt: Double?
    public var firstAudioChunkAt: Double?
    public var firstAudibleAt: Double?
    public var bargeInDetectedAt: Double?
    public var playbackStoppedAt: Double?

    public init() {}

    /// speech end → first audible output (the headline conversational latency), when both are known.
    public var speechEndToAudibleMs: Double? {
        guard let a = speechEndedAt, let b = firstAudibleAt, b >= a else { return nil }
        return (b - a) * 1000
    }
    /// speech end → final transcript.
    public var finalSTTMs: Double? {
        guard let a = speechEndedAt, let b = finalTranscriptAt, b >= a else { return nil }
        return (b - a) * 1000
    }
    /// barge-in speech start → playback stopped (the headline interruption latency).
    public var bargeInToStoppedMs: Double? {
        guard let a = bargeInDetectedAt, let b = playbackStoppedAt, b >= a else { return nil }
        return (b - a) * 1000
    }
}
