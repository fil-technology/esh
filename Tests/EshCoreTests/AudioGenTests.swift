import Foundation
import Testing
@testable import EshCore

@Suite
struct AudioGenTests {
    private let router = DeterministicIntentRouter()
    private func cap(_ m: String) -> CapabilityID? { router.route(message: m, inputModalities: []).capability }

    // MARK: - Router: the frozen sound fixtures → audio.generate
    @Test func frozenSoundPromptsRouteToAudioGenerate() {
        for m in [
            "Generate 20 seconds of gentle rain in a dense forest, with distant birds and no music.",
            "Generate 20 seconds of waves hitting a rocky shore with light coastal wind.",
            "Generate 15 seconds of a close fireplace crackling in a quiet room.",
            "Generate 20 seconds of a busy café ambience with indistinct conversation and cups, but no intelligible speech.",
            "Generate footsteps walking across wet pavement at night.",
            "Generate distant thunder and rain without music.",
            "Generate a calm continuous nighttime forest ambience suitable for looping.",
            "generate 5 seconds of white noise",
        ] {
            #expect(cap(m) == .audioGenerate, "\(m) → \(String(describing: cap(m)))")
        }
    }

    // MARK: - Router: the frozen music fixtures → music.generate
    @Test func frozenMusicPromptsRouteToMusicGenerate() {
        for m in [
            "Create a 30-second warm ambient synth with an evolving pad and no drums.",
            "Create a 30-second cinematic orchestral cue building tension.",
            "Create a 30-second instrumental lo-fi study loop.",
            "Create a short melancholic solo piano with a memorable motif.",
            "Create a 30-second retro-futuristic electronic game soundtrack loop.",
        ] {
            #expect(cap(m) == .musicGenerate, "\(m) → \(String(describing: cap(m)))")
        }
    }

    // MARK: - Router: audio doesn't steal visual/web/speech asks
    @Test func audioDoesNotStealOtherGenerations() {
        #expect(cap("create a static landing page for a cafe") == .webArtifactGenerate)
        #expect(cap("generate a photo of a rainy forest") == .imageGenerate)
        #expect(cap("generate an svg logo of a wave") == .vectorGenerate)
    }

    // MARK: - Deterministic DSP
    @Test func classifiesDeterministicWaveforms() {
        #expect(DeterministicAudio.classify("5 seconds of white noise") == .white)
        #expect(DeterministicAudio.classify("pink noise for sleep") == .pink)
        #expect(DeterministicAudio.classify("brown noise") == .brown)
        #expect(DeterministicAudio.classify("a 440 Hz sine tone") == .tone)
        #expect(DeterministicAudio.classify("a frequency sweep from low to high") == .sweep)
        #expect(DeterministicAudio.classify("2 seconds of silence") == .silence)
        #expect(DeterministicAudio.classify("gentle rain in a forest") == nil)   // needs a neural model
    }

    @Test func parsesDurationAndFrequency() {
        #expect(DeterministicAudio.duration("30 seconds of white noise") == 30)
        #expect(DeterministicAudio.duration("2 minutes of rain") == 120)
        #expect(DeterministicAudio.duration("white noise") == 10)               // default
        #expect(DeterministicAudio.frequency("a 1 kHz test tone") == 1000)
        #expect(DeterministicAudio.frequency("a 440 Hz tone") == 440)
    }

    @Test func producesValidWav() {
        let mono = DeterministicAudio.samples(.white, seconds: 1, sampleRate: 44100, seed: 7)
        #expect(mono.count == 44100)
        let wav = DeterministicAudio.wav(mono, sampleRate: 44100, channels: 2)
        #expect(wav.prefix(4) == Data("RIFF".utf8))
        #expect(wav.subdata(in: 8..<12) == Data("WAVE".utf8))
        let v = AudioArtifactComposer.validateWAV(wav, expectedSeconds: 1)
        #expect(v.isValid)
        // Deterministic: same seed → identical samples.
        let again = DeterministicAudio.samples(.white, seconds: 1, sampleRate: 44100, seed: 7)
        #expect(mono == again)
        // Silence is structurally valid (an explicit silence request is legitimate) but flagged as a finding.
        let silence = DeterministicAudio.wav(DeterministicAudio.samples(.silence, seconds: 1, sampleRate: 8000, seed: 1), sampleRate: 8000, channels: 1)
        let sv = AudioArtifactComposer.validateWAV(silence, expectedSeconds: 1)
        #expect(sv.isValid)
        #expect(sv.findings.contains { $0.contains("silent") })
        // A duration mismatch IS a hard failure.
        #expect(AudioArtifactComposer.validateWAV(wav, expectedSeconds: 30).isValid == false)
    }
}
