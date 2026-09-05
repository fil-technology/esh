import Foundation

// esh 2.1 — Voice 2.1 server-side VAD / endpointing (spec §5). The canonical detector must live on the server,
// not in the browser. This is the reliable ACOUSTIC baseline: frame RMS energy with start/end hysteresis and a
// max-utterance safety cap. It is deterministic and unit-tested (no hardware). It also runs DURING assistant
// playback so it can drive barge-in.
//
// Research note (upgrade path, evidence-driven): a learned VAD — Silero VAD (small, permissive, ONNX) or
// sherpa-onnx VAD — gives better quiet-speech / noise robustness than pure energy and is the recommended next
// step; Apple's voice-processing I/O unit additionally provides echo cancellation for the built-in-speaker
// case. This energy baseline is the honest, dependency-free starting point; the endpointer is a protocol seam
// so a learned model drops in without changing the orchestrator.

/// A decision emitted by an endpointer as audio frames arrive.
public enum VADSignal: Sendable, Equatable {
    case level(Double)        // per-frame RMS (0…1), for the meter
    case speechStarted
    case speechEnded          // endpoint reached (trailing silence, or max-utterance cap)
}

/// Stateless-config, stateful-progress acoustic endpointer over normalized PCM frames (samples in −1…1).
public struct EnergyVADEndpointer: Sendable {
    public let sampleRate: Int
    public let energyThreshold: Double
    public let minSpeechMs: Int
    public let trailingSilenceMs: Int
    public let maxUtteranceMs: Int

    public init(sampleRate: Int = 16000,
                policy: VoiceEndpointPolicy = .init(),
                minSpeechMs: Int = 200) {
        self.sampleRate = max(8000, sampleRate)
        self.energyThreshold = policy.speechEnergyThreshold
        self.trailingSilenceMs = policy.trailingSilenceMs
        self.maxUtteranceMs = policy.maxUtteranceMs
        self.minSpeechMs = max(0, minSpeechMs)
    }

    /// Progress carried between frames (value type — the caller owns it, keeping the endpointer testable).
    public struct State: Sendable, Equatable {
        var inSpeech = false
        var speechAccumMs = 0     // contiguous speech time before we declare start
        var silenceAccumMs = 0    // contiguous silence after speech, toward the endpoint
        var utteranceMs = 0       // total time since speech started (max-utterance cap)
        var started = false
        public init() {}
    }

    /// Feed one frame of normalized samples; returns the signals it produced (in order). Deterministic.
    public func process(frame: [Float], state: inout State) -> [VADSignal] {
        guard !frame.isEmpty else { return [] }
        let frameMs = Int((Double(frame.count) / Double(sampleRate)) * 1000.0)
        let rms = Self.rms(frame)
        var out: [VADSignal] = [.level(rms)]
        let isSpeech = rms >= energyThreshold

        if !state.started {
            if isSpeech {
                state.speechAccumMs += frameMs
                if state.speechAccumMs >= minSpeechMs {
                    state.started = true
                    state.inSpeech = true
                    state.silenceAccumMs = 0
                    state.utteranceMs = state.speechAccumMs
                    out.append(.speechStarted)
                }
            } else {
                state.speechAccumMs = 0
            }
            return out
        }

        // In an active utterance: accumulate, and end on trailing silence or the max-utterance cap.
        state.utteranceMs += frameMs
        if isSpeech {
            state.silenceAccumMs = 0
        } else {
            state.silenceAccumMs += frameMs
        }
        if state.silenceAccumMs >= trailingSilenceMs || state.utteranceMs >= maxUtteranceMs {
            out.append(.speechEnded)
            state = State()   // ready for the next utterance
        }
        return out
    }

    /// Root-mean-square energy of normalized samples (0…1).
    public static func rms(_ frame: [Float]) -> Double {
        guard !frame.isEmpty else { return 0 }
        var sum = 0.0
        for s in frame { let v = Double(s); sum += v * v }
        return (sum / Double(frame.count)).squareRoot()
    }

    /// Convenience: convert little-endian PCM16 bytes to normalized Float samples.
    public static func pcm16ToFloat(_ data: Data) -> [Float] {
        let count = data.count / 2
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<count { out[i] = Float(Int16(littleEndian: p[i])) / 32768.0 }
        }
        return out
    }
}
