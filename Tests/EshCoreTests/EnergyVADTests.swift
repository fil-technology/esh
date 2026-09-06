import Foundation
import Testing
@testable import EshCore

@Suite
struct EnergyVADTests {
    private let sr = 16000
    private func frame(_ amplitude: Float, ms: Int = 20) -> [Float] {
        let n = (sr * ms) / 1000
        return [Float](repeating: amplitude, count: n)   // constant |amp| → RMS == amplitude
    }

    @Test
    func detectsSpeechStartAfterMinSpeechAndEndsOnTrailingSilence() {
        // trailingSilenceMs floors at 200 in VoiceEndpointPolicy; use 200 (→ 10 frames of 20ms).
        let policy = VoiceEndpointPolicy(trailingSilenceMs: 200, maxUtteranceMs: 30_000, speechEnergyThreshold: 0.045)
        let vad = EnergyVADEndpointer(sampleRate: sr, policy: policy, minSpeechMs: 60)
        var state = EnergyVADEndpointer.State()
        var signals: [VADSignal] = []

        for _ in 0..<3 { signals += vad.process(frame: frame(0.0), state: &state) }   // silence: nothing
        #expect(!signals.contains(.speechStarted))
        for _ in 0..<5 { signals += vad.process(frame: frame(0.2), state: &state) }   // loud 100ms → start
        #expect(signals.contains(.speechStarted))
        #expect(!signals.contains(.speechEnded))
        for _ in 0..<12 { signals += vad.process(frame: frame(0.0), state: &state) }  // 240ms silence → end
        #expect(signals.contains(.speechEnded))
        // Order: start precedes end.
        let startIdx = signals.firstIndex(of: .speechStarted)!
        let endIdx = signals.firstIndex(of: .speechEnded)!
        #expect(startIdx < endIdx)
    }

    @Test
    func briefBlipBelowMinSpeechDoesNotTriggerStart() {
        let policy = VoiceEndpointPolicy(trailingSilenceMs: 100, speechEnergyThreshold: 0.045)
        let vad = EnergyVADEndpointer(sampleRate: sr, policy: policy, minSpeechMs: 100)
        var state = EnergyVADEndpointer.State()
        var signals: [VADSignal] = []
        signals += vad.process(frame: frame(0.2, ms: 20), state: &state)  // 20ms blip < 100ms min
        for _ in 0..<3 { signals += vad.process(frame: frame(0.0), state: &state) }
        #expect(!signals.contains(.speechStarted))
    }

    @Test
    func maxUtteranceCapForcesEndpoint() {
        // maxUtteranceMs floors at 1000; use 1000 (→ 50 frames of 20ms) with effectively no trailing-silence end.
        let policy = VoiceEndpointPolicy(trailingSilenceMs: 100_000, maxUtteranceMs: 1000, speechEnergyThreshold: 0.045)
        let vad = EnergyVADEndpointer(sampleRate: sr, policy: policy, minSpeechMs: 20)
        var state = EnergyVADEndpointer.State()
        var signals: [VADSignal] = []
        for _ in 0..<55 { signals += vad.process(frame: frame(0.2), state: &state) }  // continuous speech > 1000ms
        #expect(signals.contains(.speechStarted))
        #expect(signals.contains(.speechEnded))   // capped at 1000ms despite no silence
    }

    @Test
    func echoGuardSuppressesQuietEchoButNotLoudSpeechDuringPlayback() {
        // While the assistant speaks, the server raises the VAD bar (thresholdScale). Quiet echo (~0.08 RMS)
        // stays below the raised bar (0.045×3 = 0.135) so it can't self-interrupt; genuine louder speech (~0.24)
        // still crosses it and barges in. Base threshold 0.045; minSpeech 60 ms.
        let policy = VoiceEndpointPolicy(trailingSilenceMs: 200, speechEnergyThreshold: 0.045)
        let vad = EnergyVADEndpointer(sampleRate: sr, policy: policy, minSpeechMs: 60)

        var echoState = EnergyVADEndpointer.State(); var echoSignals: [VADSignal] = []
        for _ in 0..<20 { echoSignals += vad.process(frame: frame(0.08), state: &echoState, thresholdScale: 3.0) }
        #expect(!echoSignals.contains(.speechStarted), "quiet echo must NOT trigger speech during playback")

        var loudState = EnergyVADEndpointer.State(); var loudSignals: [VADSignal] = []
        for _ in 0..<20 { loudSignals += vad.process(frame: frame(0.24), state: &loudState, thresholdScale: 3.0) }
        #expect(loudSignals.contains(.speechStarted), "loud genuine speech must still barge in during playback")

        // And with no playback (scale 1.0) the same quiet 0.08 DOES count as speech (bar is only raised while speaking).
        var normalState = EnergyVADEndpointer.State(); var normalSignals: [VADSignal] = []
        for _ in 0..<20 { normalSignals += vad.process(frame: frame(0.08), state: &normalState, thresholdScale: 1.0) }
        #expect(normalSignals.contains(.speechStarted))
    }

    @Test
    func rmsAndPCM16Conversion() {
        #expect(EnergyVADEndpointer.rms([0.5, -0.5, 0.5, -0.5]) == 0.5)
        var d = Data(); var s: Int16 = 16384; withUnsafeBytes(of: s.littleEndian) { d.append(contentsOf: $0) }
        s = -16384; withUnsafeBytes(of: s.littleEndian) { d.append(contentsOf: $0) }
        let f = EnergyVADEndpointer.pcm16ToFloat(d)
        #expect(f.count == 2)
        #expect(abs(f[0] - 0.5) < 0.001 && abs(f[1] + 0.5) < 0.001)
    }
}
