import Foundation

// esh 2.1 — Voice 2.1 collaborator protocols. The orchestrator depends only on these narrow async seams, so
// it is unit-testable with fakes and wired to the real backends via thin adapters (STT → SpeechRuntimeManager,
// inference → the language provider, TTS → TTSMLX's streaming path). Keeping these abstract is what lets the
// canonical runtime exist without duplicating the speech backends.

/// A captured user utterance handed to STT (opaque bytes + container/codec hint).
public struct VoiceAudioInput: Sendable, Equatable {
    public var bytes: Data
    public var format: String     // e.g. "wav", "webm", "m4a"
    public var sampleRate: Int?
    public init(bytes: Data, format: String, sampleRate: Int? = nil) {
        self.bytes = bytes
        self.format = format
        self.sampleRate = sampleRate
    }
}

public enum VoiceProviderError: Error, Sendable, Equatable {
    case sttUnavailable(String)
    case ttsUnavailable(String)
    case inferenceUnavailable(String)
}

/// Speech-to-text. `transcribe` returns the final text for a whole utterance (today's warm speech-serve path);
/// a streaming implementation can additionally emit partials via `partials` (default: none).
public protocol VoiceTranscriber: Sendable {
    func transcribe(_ audio: VoiceAudioInput, language: String?, model: String?) async throws -> String
}

/// Conversational inference: stream assistant text deltas for the current bounded context. Cancellation of the
/// consuming task must stop generation (the orchestrator relies on this for barge-in).
public protocol VoiceResponder: Sendable {
    func respond(context: [VoiceTurn], language: String?, model: String?) -> AsyncThrowingStream<String, Error>
}

/// Text-to-speech: stream audio chunks for a piece of text (a phrase/sentence). Cancellation must stop
/// synthesis/playback promptly (barge-in). A buffered backend may yield a single final chunk.
public protocol VoiceSpeaker: Sendable {
    func speak(_ text: String, language: String?, model: String?) -> AsyncThrowingStream<VoiceAudioChunk, Error>
}

/// Split streamed assistant text into speakable phrase chunks at sentence boundaries so TTS (and audible
/// output) can begin after the first phrase instead of the whole reply — the low-latency pumping the browser
/// loop does today, lifted into the reusable runtime. Deterministic and side-effect free (unit-tested).
public struct VoicePhraseChunker: Sendable {
    public let minChunkCharacters: Int
    private static let boundaries: Set<Character> = [".", "!", "?", "…", "\n", ";", ":", "。", "！", "？"]

    public init(minChunkCharacters: Int = 12) {
        self.minChunkCharacters = max(1, minChunkCharacters)
    }

    /// Feed a text delta; returns any completed phrase chunks now ready to speak. Remaining text is buffered.
    public func ingest(_ delta: String, into buffer: inout String) -> [String] {
        buffer += delta
        var out: [String] = []
        var current = ""
        var pending = ""
        for ch in buffer {
            current.append(ch)
            if Self.boundaries.contains(ch), current.trimmingCharacters(in: .whitespacesAndNewlines).count >= minChunkCharacters {
                out.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            }
        }
        pending = current
        buffer = pending
        return out.filter { !$0.isEmpty }
    }

    /// Flush whatever remains at end-of-stream as a final chunk (if non-trivial).
    public func flush(_ buffer: inout String) -> String? {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return rest.isEmpty ? nil : rest
    }
}
