import Foundation

// esh 2.1 — Voice 2.1 combined Model Fit + Voice Auto (spec §9/§10). A voice turn keeps STT + LLM + TTS
// resident together, plus VAD/audio/transport buffers, so Fit must model the WHOLE stack, not each model
// alone. Voice Auto then picks a compatible LLM from installed models honoring explicit pins (Router chooses
// WHAT, Scheduler chooses HOW). Pure + unit-tested.

/// Rough per-component memory (GB) for a resident voice stack. Defaults reflect the measured local stack
/// (Parakeet STT ~1 GB warm, Pocket-TTS ~1 GB, small audio/transport buffers).
public struct VoiceFitInput: Sendable {
    public var sttGB: Double
    public var ttsGB: Double
    public var llmWeightsGB: Double
    public var llmKVGB: Double          // context/KV for the voice conversation (bounded)
    public var runtimeOverheadGB: Double
    public var audioBuffersGB: Double
    public init(sttGB: Double = 1.0, ttsGB: Double = 1.0, llmWeightsGB: Double,
                llmKVGB: Double = 0.5, runtimeOverheadGB: Double = 1.0, audioBuffersGB: Double = 0.25) {
        self.sttGB = sttGB; self.ttsGB = ttsGB; self.llmWeightsGB = llmWeightsGB
        self.llmKVGB = llmKVGB; self.runtimeOverheadGB = runtimeOverheadGB; self.audioBuffersGB = audioBuffersGB
    }
    public var peakGB: Double { sttGB + ttsGB + llmWeightsGB + llmKVGB + runtimeOverheadGB + audioBuffersGB }
}

public struct VoiceFitResult: Sendable, Equatable {
    public var peakGB: Double
    public var usableGB: Double
    public var fitClass: ModelFitClass
    public var reason: String
}

public enum VoiceFit {
    /// Classify the whole voice stack against the host's usable budget (total − OS reserve). Conservative:
    /// comfortable ≤ 0.6·usable, fits ≤ usable, tight ≤ 0.9·total, else unlikely; unsupported if it can't fit.
    public static func assess(_ input: VoiceFitInput, host: HostMachineProfile) -> VoiceFitResult {
        let total = host.totalMemoryGB ?? 16
        let osReserve = max(3, total * 0.2)
        let usable = max(1, total - osReserve)
        let peak = input.peakGB
        let cls: ModelFitClass
        if peak <= usable * 0.6 { cls = .comfortable }
        else if peak <= usable { cls = .fits }
        else if peak <= total * 0.9 { cls = .tight }
        else if peak <= total { cls = .unlikely }
        else { cls = .unsupported }
        let reason = String(format: "voice stack peak ~%.1f GB (STT %.1f + LLM %.1f + KV %.1f + TTS %.1f + rt %.1f + audio %.2f) vs ~%.1f GB usable of %.0f GB",
                            peak, input.sttGB, input.llmWeightsGB, input.llmKVGB, input.ttsGB, input.runtimeOverheadGB, input.audioBuffersGB, usable, total)
        return VoiceFitResult(peakGB: peak, usableGB: usable, fitClass: cls, reason: reason)
    }
}

/// Minimal Voice-Auto policy: honor an explicit compatible pin; otherwise pick an installed LLM whose combined
/// voice stack fits with headroom, preferring the SMALLEST such model (lower latency/memory for realtime) —
/// evidence (measured latency) can later refine this. The Router never chooses a concrete model; this does.
public struct VoiceAutoCandidate: Sendable, Equatable {
    public var id: String
    public var weightsGB: Double
    public var fit: ModelFitClass
    public init(id: String, weightsGB: Double, fit: ModelFitClass) { self.id = id; self.weightsGB = weightsGB; self.fit = fit }
}

public enum VoiceAuto {
    /// `installed` = (id, approx weights GB). Returns the chosen LLM id + why, or nil if none fits.
    public static func selectLLM(installed: [(id: String, weightsGB: Double)],
                                 pinned: String?, host: HostMachineProfile) -> (id: String, reason: String)? {
        if let pinned, installed.contains(where: { $0.id == pinned }) {
            return (pinned, "explicit pin honored")
        }
        // Rank installed models that fit the combined voice stack, smallest-first (realtime-friendly).
        let ranked = installed
            .map { m -> (String, Double, ModelFitClass) in
                let fit = VoiceFit.assess(VoiceFitInput(llmWeightsGB: m.weightsGB), host: host).fitClass
                return (m.id, m.weightsGB, fit)
            }
            .filter { $0.2 != .unsupported && $0.2 != .unlikely }
            .sorted { $0.1 < $1.1 }
        guard let best = ranked.first else { return nil }
        return (best.0, "smallest installed model that fits the warm voice stack (\(String(format: "%.1f", best.1)) GB, \(best.2.rawValue))")
    }
}
