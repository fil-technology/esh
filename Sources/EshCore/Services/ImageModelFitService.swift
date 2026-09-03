import Foundation

// esh 2.1 UCMR, Stage 3 — Model Fit for image-generation models. Diffusion fit differs from LLM fit:
// there is no KV cache growing with context; instead working memory scales with the requested output
// RESOLUTION (latent + activation maps), on top of the resident weights and a fixed runtime overhead.
// This reuses the same fit language (ModelFitClass) and ModelFitAssessment shape as LLM fit, so image
// generation does NOT bypass esh's hardware-awareness — it is the same gate with a diffusion memory model.

public struct ImageModelFitService: Sendable {
    private let storage: StorageService
    public init(storage: StorageService = .init()) { self.storage = storage }

    public struct Input: Sendable {
        /// Resident weights footprint (≈ on-disk size of the quantized weights). nil → unknown.
        public var weightsGB: Double?
        /// Fixed runtime overhead: MLX/diffusion runtime + text encoder(s) + VAE resident, etc.
        public var runtimeOverheadGB: Double
        public var width: Int
        public var height: Int
        public var backendSupported: Bool
        public var architectureSupported: Bool
        public var macOSSupported: Bool
        /// On-disk bytes the model download requires (for the disk-space gate). nil → skip disk gate.
        public var diskRequiredBytes: Int64?
        /// Memory already committed to other resident models (LLMs, speech).
        public var otherResidentGB: Double

        public init(weightsGB: Double?, runtimeOverheadGB: Double = 1.0, width: Int = 1024, height: Int = 1024,
                    backendSupported: Bool = true, architectureSupported: Bool = true, macOSSupported: Bool = true,
                    diskRequiredBytes: Int64? = nil, otherResidentGB: Double = 0) {
            self.weightsGB = weightsGB
            self.runtimeOverheadGB = runtimeOverheadGB
            self.width = width
            self.height = height
            self.backendSupported = backendSupported
            self.architectureSupported = architectureSupported
            self.macOSSupported = macOSSupported
            self.diskRequiredBytes = diskRequiredBytes
            self.otherResidentGB = otherResidentGB
        }
    }

    /// Resolution-aware working-memory heuristic for diffusion (latent + activation maps). Deliberately
    /// a transparent heuristic, not a measured value: ~0.6 GB base + ~1.8 GB per megapixel of output.
    /// Benchmarks (Stage 3 item 3) refine the real peak per model/resolution over time.
    public static func workingMemoryGB(width: Int, height: Int) -> Double {
        let megapixels = Double(max(1, width) * max(1, height)) / (1024.0 * 1024.0)
        return 0.6 + 1.8 * megapixels
    }

    public func assess(input: Input, host: HostMachineProfile, root: PersistenceRoot) -> ModelFitAssessment {
        let availability = storage.availability(root: root)
        let storageAvailable = availability.isUsable
        let diskFreeBytes = availability.freeBytes ?? SystemStorage.snapshot(at: root.stateRootURL)?.availableBytes
        let diskFreeGB = diskFreeBytes.map { Double($0) / 1_073_741_824 }
        let diskRequiredGB = input.diskRequiredBytes.map { Double($0) / 1_073_741_824 }
        let diskSufficient = (input.diskRequiredBytes == nil) || (diskFreeBytes ?? 0) >= (input.diskRequiredBytes ?? 0)

        // Hard technical incompatibility -> unsupported.
        var blockers: [String] = []
        if !input.backendSupported { blockers.append("the diffusion runtime is not available on this Mac") }
        if !input.architectureSupported { blockers.append("this image model is not supported by esh's current runtimes") }
        if !input.macOSSupported { blockers.append("this model/runtime requires a newer macOS") }
        if !blockers.isEmpty {
            return ModelFitAssessment(
                fitClass: .unsupported,
                diskRequiredGB: diskRequiredGB.map(round1), diskFreeGB: diskFreeGB.map(round1),
                diskSufficient: diskSufficient, storageAvailable: storageAvailable,
                reasons: ["This image model cannot run through esh on this Mac."], blockers: blockers)
        }

        guard let weightsGB = input.weightsGB else {
            return ModelFitAssessment(
                fitClass: .unknown,
                usableMemoryGB: host.safeBudgetGB.map(round1),
                totalMemoryGB: host.totalMemoryGB.map(round1),
                diskRequiredGB: diskRequiredGB.map(round1), diskFreeGB: diskFreeGB.map(round1),
                diskSufficient: diskSufficient, storageAvailable: storageAvailable,
                reasons: ["Could not estimate memory: the image model's weight size is unknown."]
                    + (diskSufficient ? [] : ["Target storage may not have enough free space."]))
        }

        let total = host.totalMemoryGB ?? 0
        let osReserveGB = max(3.0, total * 0.2)
        let usableGB = max(1.0, total - osReserveGB)
        let workingGB = Self.workingMemoryGB(width: input.width, height: input.height)
        let peakGB = weightsGB + input.runtimeOverheadGB + workingGB + input.otherResidentGB

        var breakdown: [String: Double] = [
            "weights": round1(weightsGB),
            "runtimeOverhead": round1(input.runtimeOverheadGB),
            "working@\(input.width)x\(input.height)": round1(workingGB),
            "osReserve": round1(osReserveGB)
        ]
        if input.otherResidentGB > 0 { breakdown["otherResidentModels"] = round1(input.otherResidentGB) }

        var reasons: [String] = [
            String(format: "estimated peak ~%.1f GB (weights %.1f GB + working ~%.1f GB at %dx%d) vs ~%.1f GB usable of %.0f GB",
                   peakGB, weightsGB, workingGB, input.width, input.height, usableGB, total),
            // Honest caveat (Stage 3 item 6): this is a MEMORY fit only. Fitting comfortably in memory does
            // NOT imply fast generation — diffusion latency is compute-bound and scales strongly with
            // resolution (e.g. Z-Image-Turbo 6B measured ~215s at 1024² vs ~51s at 512² on M1 Pro, same
            // ~4.4 GB peak). Scheduler/Auto should weigh benchmark seconds/image, not just memory.
            "memory fit only — generation speed is compute-bound and scales with resolution (see image benchmarks)"
        ]
        if input.otherResidentGB > 0 { reasons.append(String(format: "reserving %.1f GB for models already resident", input.otherResidentGB)) }

        let fitClass: ModelFitClass
        if peakGB <= usableGB * 0.6 {
            fitClass = .comfortable
        } else if peakGB <= usableGB {
            fitClass = .fits
        } else if peakGB <= total * 0.9 {
            fitClass = .tight
            reasons.append("above the safe budget — other apps may feel memory pressure; consider a lower resolution")
        } else {
            fitClass = .unlikely
            reasons.append("estimated peak exceeds usable memory — lower the resolution or free resident models")
        }

        var expectedOptimization: String?
        if fitClass == .tight || fitClass == .unlikely {
            expectedOptimization = "Reduce the requested resolution, or unload resident models, to cut peak memory."
        }
        if !diskSufficient {
            reasons.append(String(format: "target storage has ~%.1f GB free but needs ~%.1f GB", diskFreeGB ?? 0, diskRequiredGB ?? 0))
        }
        if !storageAvailable { reasons.append("the configured asset storage volume is not available") }

        return ModelFitAssessment(
            fitClass: fitClass,
            estimatedPeakMemoryGB: round1(peakGB),
            usableMemoryGB: round1(usableGB),
            totalMemoryGB: round1(total),
            diskRequiredGB: diskRequiredGB.map(round1),
            diskFreeGB: diskFreeGB.map(round1),
            diskSufficient: diskSufficient,
            storageAvailable: storageAvailable,
            expectedOptimization: expectedOptimization,
            breakdown: breakdown,
            reasons: reasons)
    }

    private func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
}
