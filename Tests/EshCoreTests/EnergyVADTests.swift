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
    func rmsAndPCM16Conversion() {
        #expect(EnergyVADEndpointer.rms([0.5, -0.5, 0.5, -0.5]) == 0.5)
        var d = Data(); var s: Int16 = 16384; withUnsafeBytes(of: s.littleEndian) { d.append(contentsOf: $0) }
        s = -16384; withUnsafeBytes(of: s.littleEndian) { d.append(contentsOf: $0) }
        let f = EnergyVADEndpointer.pcm16ToFloat(d)
        #expect(f.count == 2)
        #expect(abs(f[0] - 0.5) < 0.001 && abs(f[1] + 0.5) < 0.001)
    }
}
