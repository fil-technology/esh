import Foundation

// esh 2.1 — Voice 2.1 typed event stream (spec §4). One normalized event vocabulary for the whole runtime:
// the orchestrator emits these, a transport serializes them (dotted `name` matches esh naming conventions),
// and clients render state from them. Audio payloads are carried as opaque bytes so this stays transport- and
// codec-agnostic (the current path uses WAV/PCM chunks; a future duplex path can reuse the same events).

/// An opaque audio chunk produced by TTS (PCM or a container like WAV — `format` disambiguates).
public struct VoiceAudioChunk: Sendable, Equatable {
    public var bytes: Data
    public var sampleRate: Int
    public var format: String     // e.g. "wav", "pcm_s16le"
    public var isFinal: Bool
    public init(bytes: Data, sampleRate: Int, format: String = "wav", isFinal: Bool = false) {
        self.bytes = bytes
        self.sampleRate = sampleRate
        self.format = format
        self.isFinal = isFinal
    }
}

/// The canonical event emitted by a VoiceSession. `name` is the stable dotted identifier used on the wire.
public enum VoiceEvent: Sendable {
    case sessionStarted(VoiceSessionID)
    case stateChanged(VoiceSessionState)
    case inputLevel(Double)                       // 0…1 RMS, for a live meter
    case vadSpeechStarted
    case vadSpeechEnded
    case transcriptPartial(String)
    case transcriptFinal(String)
    case assistantThinkingStarted
    case assistantTextDelta(String)
    case assistantTextFinal(String)
    case ttsStarted
    case ttsAudioChunk(VoiceAudioChunk)
    case ttsFinished
    case interruptionDetected
    case playbackCancelled
    case sessionError(message: String, recoverable: Bool)
    case sessionEnded(reason: String)

    /// Stable dotted name (spec §4 vocabulary). Used for serialization and logging.
    public var name: String {
        switch self {
        case .sessionStarted: return "session.started"
        case .stateChanged: return "session.state"
        case .inputLevel: return "input.level"
        case .vadSpeechStarted: return "vad.speech_started"
        case .vadSpeechEnded: return "vad.speech_ended"
        case .transcriptPartial: return "transcript.partial"
        case .transcriptFinal: return "transcript.final"
        case .assistantThinkingStarted: return "assistant.thinking_started"
        case .assistantTextDelta: return "assistant.text_delta"
        case .assistantTextFinal: return "assistant.text_final"
        case .ttsStarted: return "tts.started"
        case .ttsAudioChunk: return "tts.audio_chunk"
        case .ttsFinished: return "tts.finished"
        case .interruptionDetected: return "interruption.detected"
        case .playbackCancelled: return "playback.cancelled"
        case .sessionError: return "session.error"
        case .sessionEnded: return "session.ended"
        }
    }
}
