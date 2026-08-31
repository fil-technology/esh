import Foundation

/// Assesses whether a model is expected to fit and run on this Mac BEFORE downloading multi-GB
/// weights. Produces a 6-class fit with a memory breakdown and rationale. Soft gates
/// (tight/unlikely/unknown) require explicit confirmation but are never silently blocked; only a
/// genuine technical incompatibility (`unsupported`) is blocked. Never substitutes another model.
public struct ModelFitService: Sendable {
    private let estimator: ModelMemoryEstimator
    private let storage: StorageService

    public init(estimator: ModelMemoryEstimator = .init(), storage: StorageService = .init()) {
        self.estimator = estimator
        self.storage = storage
    }

    public struct Input: Sendable {
        public var parameterCountB: Double?
        public var effectiveBits: Double?
        public var format: ModelFormat
        public var backend: BackendKind?
        public var backendSupported: Bool
        public var architectureSupported: Bool
        public var macOSSupported: Bool
        public var contextTokens: Int
        public var diskRequiredBytes: Int64?
        public var otherResidentGB: Double
        public var ttsReserveGB: Double
        public var speculativeDraftGB: Double

        public init(
            parameterCountB: Double?,
            effectiveBits: Double?,
            format: ModelFormat,
            backend: BackendKind?,
            backendSupported: Bool = true,
            architectureSupported: Bool = true,
            macOSSupported: Bool = true,
            contextTokens: Int,
            diskRequiredBytes: Int64? = nil,
            otherResidentGB: Double = 0,
            ttsReserveGB: Double = 0,
            speculativeDraftGB: Double = 0
        ) {
            self.parameterCountB = parameterCountB
            self.effectiveBits = effectiveBits
            self.format = format
            self.backend = backend
            self.backendSupported = backendSupported
            self.architectureSupported = architectureSupported
            self.macOSSupported = macOSSupported
            self.contextTokens = contextTokens
            self.diskRequiredBytes = diskRequiredBytes
            self.otherResidentGB = otherResidentGB
            self.ttsReserveGB = ttsReserveGB
            self.speculativeDraftGB = speculativeDraftGB
        }
    }

    public func assess(input: Input, host: HostMachineProfile, root: PersistenceRoot) -> ModelFitAssessment {
        let availability = storage.availability(root: root)
        let storageAvailable = availability.isUsable
        let diskFreeBytes = availability.freeBytes ?? SystemStorage.snapshot(at: root.stateRootURL)?.availableBytes
        let diskFreeGB = diskFreeBytes.map { Double($0) / 1_073_741_824 }
        let diskRequiredGB = input.diskRequiredBytes.map { Double($0) / 1_073_741_824 }
        let diskSufficient = (input.diskRequiredBytes == nil) || (diskFreeBytes ?? 0) >= (input.diskRequiredBytes ?? 0)

        // Hard technical incompatibility -> unsupported (the only hard block).
        var blockers: [String] = []
        if !input.backendSupported { blockers.append("the required backend (\(input.backend?.rawValue ?? "unknown")) is not available on this Mac") }
        if !input.architectureSupported { blockers.append("the model architecture is not supported by esh's current runtimes") }
        if !input.macOSSupported { blockers.append("this model/runtime requires a newer macOS") }
        if !blockers.isEmpty {
            return ModelFitAssessment(
                fitClass: .unsupported,
                diskRequiredGB: diskRequiredGB.map(round1), diskFreeGB: diskFreeGB.map(round1),
                diskSufficient: diskSufficient, storageAvailable: storageAvailable,
                reasons: ["This model cannot run through esh on this Mac."],
                blockers: blockers
            )
        }

        let estimate = estimator.estimate(
            parameterCountB: input.parameterCountB,
            effectiveBits: input.effectiveBits,
            quantization: nil,
            contextTokens: input.contextTokens,
            format: input.format
        )

        guard let runtimeGB = estimate.runtimeGB, let weightsGB = estimate.weightsGB else {
            // Not enough metadata: honest "unknown" — allow deliberate override.
            return ModelFitAssessment(
                fitClass: .unknown,
                usableMemoryGB: host.safeBudgetGB.map(round1),
                totalMemoryGB: host.totalMemoryGB.map(round1),
                diskRequiredGB: diskRequiredGB.map(round1), diskFreeGB: diskFreeGB.map(round1),
                diskSufficient: diskSufficient, storageAvailable: storageAvailable,
                reasons: ["Could not estimate memory: model parameter count or quantization is unknown."]
                    + (diskSufficient ? [] : ["Target storage may not have enough free space."])
            )
        }

        let total = host.totalMemoryGB ?? 0
        // Pre-download budget is based on TOTAL unified memory minus a reasonable OS/app reserve,
        // NOT current availability (which is volatile and the model runs later). Current pressure
        // is the Adaptive Scheduler's concern (M9), not the install-time fit gate.
        let osReserveGB = max(3.0, total * 0.2)
        let usableGB = max(1.0, total - osReserveGB)
        let peakGB = runtimeGB + input.otherResidentGB + input.ttsReserveGB + input.speculativeDraftGB

        var breakdown: [String: Double] = [
            "weights": round1(weightsGB),
            "runtime+kv": round1(runtimeGB - weightsGB),
            "osReserve": round1(osReserveGB)
        ]
        if input.otherResidentGB > 0 { breakdown["otherResidentModels"] = round1(input.otherResidentGB) }
        if input.ttsReserveGB > 0 { breakdown["ttsReserve"] = round1(input.ttsReserveGB) }
        if input.speculativeDraftGB > 0 { breakdown["speculativeDraft"] = round1(input.speculativeDraftGB) }

        var reasons: [String] = []
        reasons.append(String(format: "estimated peak ~%.1f GB (weights %.1f GB) vs ~%.1f GB usable of %.0f GB", peakGB, weightsGB, usableGB, total))
        if input.otherResidentGB > 0 { reasons.append(String(format: "reserving %.1f GB for models already resident", input.otherResidentGB)) }

        let fitClass: ModelFitClass
        if peakGB <= usableGB * 0.6 {
            fitClass = .comfortable
        } else if peakGB <= usableGB {
            fitClass = .fits
        } else if peakGB <= total * 0.9 {
            fitClass = .tight
            reasons.append("above the safe budget — other apps may feel memory pressure")
        } else {
            fitClass = .unlikely
            reasons.append("estimated peak exceeds usable memory — likely to swap heavily or fail to load")
        }
        let safe = usableGB

        // Optimization / context guidance for tight/unlikely.
        var expectedOptimization: String?
        var recommendedContext: Int?
        if fitClass == .tight || fitClass == .unlikely {
            expectedOptimization = "Reduce context or use `esh performance memory` (KV quantization) to cut memory."
            let contextGB = runtimeGB - weightsGB * (input.format == .gguf ? 1.18 : 1.22)
            if contextGB > 0.5, input.contextTokens > 4096 {
                recommendedContext = max(4096, input.contextTokens / 2)
            }
        }
        if !diskSufficient {
            reasons.append(String(format: "target storage has ~%.1f GB free but needs ~%.1f GB", diskFreeGB ?? 0, diskRequiredGB ?? 0))
        }
        if !storageAvailable {
            reasons.append("the configured asset storage volume is not available")
        }

        return ModelFitAssessment(
            fitClass: fitClass,
            estimatedPeakMemoryGB: round1(peakGB),
            usableMemoryGB: round1(safe),
            totalMemoryGB: round1(total),
            diskRequiredGB: diskRequiredGB.map(round1),
            diskFreeGB: diskFreeGB.map(round1),
            diskSufficient: diskSufficient,
            storageAvailable: storageAvailable,
            recommendedContext: recommendedContext,
            expectedOptimization: expectedOptimization,
            breakdown: breakdown,
            reasons: reasons
        )
    }

    // MARK: - Convenience for catalog entries

    public func assess(recommendedModel model: RecommendedModel, contextTokens: Int?, host: HostMachineProfile, root: PersistenceRoot, otherResidentGB: Double = 0) -> ModelFitAssessment {
        let input = Input(
            parameterCountB: Self.parseParameterCount(model.parameterSize),
            effectiveBits: Self.parseEffectiveBits(model.quantization),
            format: model.backend == .gguf ? .gguf : .mlx,
            backend: model.backend,
            backendSupported: true,
            architectureSupported: model.status != .incompatible,
            contextTokens: contextTokens ?? min(model.contextWindow ?? 8192, 8192),
            diskRequiredBytes: Int64(model.totalDiskSizeGB * 1.1 * 1_073_741_824),
            otherResidentGB: otherResidentGB
        )
        return assess(input: input, host: host, root: root)
    }

    public static func parseParameterCount(_ text: String) -> Double? {
        let lower = text.lowercased().replacingOccurrences(of: " ", with: "")
        if lower.hasSuffix("b"), let v = Double(lower.dropLast()) { return v }
        if lower.hasSuffix("m"), let v = Double(lower.dropLast()) { return v / 1000 }
        return Double(lower)
    }

    public static func parseEffectiveBits(_ quantization: String) -> Double? {
        let lower = quantization.lowercased()
        // Full precision first (so "fp16"/"bf16" isn't caught by a digit match).
        if lower.contains("fp16") || lower.contains("f16") || lower.contains("bf16") || lower.contains("fp32") { return 16 }
        if lower.contains("q8") || lower.contains("8-bit") || lower.contains("8bit") || lower == "8" { return 8 }
        if lower.contains("q6") || lower.contains("6-bit") || lower.contains("6bit") || lower == "6" { return 6.5 }
        if lower.contains("q5") || lower.contains("5-bit") || lower.contains("5bit") || lower == "5" { return 5.5 }
        if lower.contains("q3") || lower.contains("3-bit") || lower.contains("3bit") || lower == "3" { return 3.5 }
        if lower.contains("q4") || lower.contains("4-bit") || lower.contains("4bit") || lower == "4" { return 4.5 }
        return 4.5  // default assumption: 4-bit-ish
    }

    private func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
}
