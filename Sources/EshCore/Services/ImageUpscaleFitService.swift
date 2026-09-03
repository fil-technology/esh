import Foundation

// esh 2.1 — Stage 3: modality-aware fit for image.upscale. The lesson from image generation is baked in
// here: MEMORY FIT ≠ USEFUL PERFORMANCE. So this reports the two SEPARATELY — a memory-fit class from the
// estimated working set at the requested input resolution × scale, AND an expected latency drawn ONLY from
// measured evidence on this Mac (never a guess). If there's no evidence, latency is reported as unknown
// rather than implied by "it fits in RAM".

public struct ImageUpscaleFit: Sendable, Equatable {
    public var memoryFit: ModelFitClass
    public var estimatedPeakMemoryMB: Double
    public var outputWidth: Int
    public var outputHeight: Int
    /// Expected wall-clock seconds for this input+scale, from measured evidence (nil = not yet benchmarked).
    public var expectedSeconds: Double?
    public var evidenceBacked: Bool
    public var tiledLikely: Bool
    public var note: String
}

public struct ImageUpscaleFitService: Sendable {
    public init() {}

    /// Assess an upscale request. `evidence` is the shared performance index (pass CapabilityEvidenceIndex(root:)).
    public func assess(inputWidth: Int, inputHeight: Int, scale: Int,
                       host: HostMachineProfile?, evidence: CapabilityEvidenceIndex,
                       tileThreshold: Int = 512) -> ImageUpscaleFit {
        let outW = inputWidth * scale, outH = inputHeight * scale
        let tiled = max(inputWidth, inputHeight) > tileThreshold
        // Peak working set. Untiled: input + output float tensors (×3ch ×4B) plus a few working copies.
        // Tiled: peak is per-tile, so it's bounded by one (tile+overlap)² tile at the given scale.
        let inPx = Double(inputWidth * inputHeight)
        let outPx = Double(outW * outH)
        let bytesPerPxFloat = 3.0 * 4.0
        let workingCopies = 3.0
        let untiledMB = (inPx + outPx) * bytesPerPxFloat * workingCopies / (1024 * 1024)
        let tilePx = Double((tileThreshold + 32) * (tileThreshold + 32))
        let tiledMB = (tilePx + tilePx * Double(scale * scale)) * bytesPerPxFloat * workingCopies / (1024 * 1024)
        // Add the onnxruntime/CoreML base (~250 MB observed) so the number reflects the real process, not just tensors.
        let baseMB = 250.0
        let estPeakMB = baseMB + (tiled ? tiledMB : untiledMB)

        _ = estPeakMB   // formula estimate is a fallback; measured peak is preferred below.

        // Expected latency + peak memory from MEASURED evidence only. Prefer an exact (width,scale) match;
        // else scale a nearby measured sample by output-pixel ratio (SR cost is ~linear in output pixels).
        var expectedSeconds: Double? = nil
        var evidenceBacked = false
        var measuredPeakMB: Double? = nil
        let pool = evidence.all(capability: .imageUpscale).filter { !($0.reliability == 0) }
        func cfgInt(_ e: CapabilityPerformanceEvidence, _ k: String) -> Int? {
            if case let .int(i)? = e.config[k] { return i }; return nil
        }
        if let exact = pool.first(where: { cfgInt($0, "width") == inputWidth && cfgInt($0, "scale") == scale }),
           let s = exact.secondsPerUnit {
            expectedSeconds = s; evidenceBacked = true; measuredPeakMB = exact.peakMemoryMB
        } else if let near = pool.filter({ cfgInt($0, "scale") == scale }).min(by: {
            abs(Double(cfgInt($0, "width") ?? 0) - Double(inputWidth)) < abs(Double(cfgInt($1, "width") ?? 0) - Double(inputWidth))
        }), let w = cfgInt(near, "width"), let s = near.secondsPerUnit {
            let measuredOutPx = Double(w * w) * Double(scale * scale)
            expectedSeconds = s * (outPx / max(measuredOutPx, 1))
            // Peak memory tracks output pixels; scale the measured peak by the output-pixel ratio.
            measuredPeakMB = near.peakMemoryMB.map { $0 * (outPx / max(measuredOutPx, 1)) }
            evidenceBacked = true
        }
        // Prefer the MEASURED peak (evidence) over the rough formula when we have it.
        let peakMB = measuredPeakMB ?? estPeakMB

        // Memory-fit class against this Mac's memory (fall back to a conservative 8 GB when unknown).
        let totalGB = host?.totalMemoryGB ?? 8
        let availGB = host?.availableMemoryGB ?? (totalGB * 0.5)
        let peakGB = peakMB / 1024
        let memoryFit: ModelFitClass
        if peakGB < availGB * 0.5 { memoryFit = .comfortable }
        else if peakGB < availGB { memoryFit = .fits }
        else if peakGB < totalGB { memoryFit = .tight }
        else { memoryFit = .unlikely }

        let peakSource = measuredPeakMB != nil ? "measured" : "est."
        let latencyText = expectedSeconds.map { String(format: "~%.1fs (measured on this Mac)", $0) } ?? "unknown (not yet benchmarked)"
        let note = "Memory fit: \(memoryFit.rawValue) (\(peakSource) peak ~\(Int(peakMB)) MB\(tiled ? ", tiled" : "")). Expected latency: \(latencyText). Memory fit does not imply interactive speed."

        return ImageUpscaleFit(memoryFit: memoryFit, estimatedPeakMemoryMB: peakMB, outputWidth: outW, outputHeight: outH,
                               expectedSeconds: expectedSeconds, evidenceBacked: evidenceBacked, tiledLikely: tiled, note: note)
    }
}
