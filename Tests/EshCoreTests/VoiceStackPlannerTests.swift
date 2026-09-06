import Foundation
import Testing
@testable import EshCore

@Suite
struct VoiceStackPlannerTests {
    private func host(_ gb: Double) -> HostMachineProfile {
        HostMachineProfile(chipDescription: "Test", totalMemoryGB: gb, availableMemoryGB: gb * 0.8)
    }

    @Test
    func combinedFitClassifiesWholeStackNotJustWeights() {
        // 3B LLM (~2 GB) + STT 1 + TTS 1 + KV .5 + rt 1 + audio .25 ≈ 5.75 GB on 32 GB → comfortable.
        let r = VoiceFit.assess(VoiceFitInput(llmWeightsGB: 2.0), host: host(32))
        #expect(r.peakGB > 5 && r.peakGB < 7)
        #expect(r.fitClass == .comfortable)
        // A 30 GB "LLM" cannot co-reside with STT+TTS on 32 GB → unsupported.
        let big = VoiceFit.assess(VoiceFitInput(llmWeightsGB: 30.0), host: host(32))
        #expect(big.fitClass == .unsupported)
    }

    @Test
    func voiceAutoHonorsPinThenPicksSmallestFitting() {
        let installed = [("qwen-0.6b", 0.6), ("llama-3b", 2.0), ("qwen-14b", 9.0)]
        // Pin wins.
        #expect(VoiceAuto.selectLLM(installed: installed, pinned: "llama-3b", host: host(32))?.id == "llama-3b")
        // No pin → smallest that fits the warm voice stack.
        #expect(VoiceAuto.selectLLM(installed: installed, pinned: nil, host: host(32))?.id == "qwen-0.6b")
        // A pin that isn't installed is ignored → falls back to auto.
        #expect(VoiceAuto.selectLLM(installed: installed, pinned: "not-installed", host: host(32))?.id == "qwen-0.6b")
        // Nothing fits on a tiny machine → nil.
        #expect(VoiceAuto.selectLLM(installed: [("huge", 40.0)], pinned: nil, host: host(8)) == nil)
    }
}
