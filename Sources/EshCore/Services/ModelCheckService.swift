import Foundation

public struct ModelCheckService: Sendable {
    private let hostProfiler: HostMachineProfileService
    private let metadataInspector: ModelMetadataInspector
    private let supportRegistry: ModelSupportRegistry
    private let memoryEstimator: ModelMemoryEstimator

    public init(
        hostProfiler: HostMachineProfileService = .init(),
        metadataInspector: ModelMetadataInspector = .init(),
        supportRegistry: ModelSupportRegistry = .init(),
        memoryEstimator: ModelMemoryEstimator = .init()
    ) {
        self.hostProfiler = hostProfiler
        self.metadataInspector = metadataInspector
        self.supportRegistry = supportRegistry
        self.memoryEstimator = memoryEstimator
    }

    public func evaluate(
        repoID: String,
        backendPreference: ModelCheckBackendPreference = .auto,
        contextTokens: Int = 4096,
        strict: Bool = false,
        offline: Bool = false,
        variant: String? = nil
    ) async throws -> ModelCheckResult {
        let host = hostProfiler.currentProfile()
        let metadata = try await metadataInspector.inspect(
            repoID: repoID,
            backendPreference: backendPreference,
            offline: offline,
            variant: variant
        )
        let backend = supportRegistry.resolveBackend(
            preference: backendPreference,
            inferredFormat: metadata.format
        ) ?? metadata.backend
        let support = supportRegistry.assess(
            backend: backend,
            format: metadata.format,
            architecture: metadata.architecture,
            isMultimodal: metadata.isMultimodal,
            hasSelectedGGUFFile: metadata.format != .gguf
                || metadata.selectedGGUFFile != nil
                || metadata.ggufFileCount == 0
        )
        let estimate = memoryEstimator.estimate(
            parameterCountB: metadata.parameterCountB,
            effectiveBits: metadata.effectiveBits,
            quantization: metadata.quantization,
            contextTokens: contextTokens,
            format: metadata.format
        )
        let verdict = selectVerdict(
            strict: strict,
            backend: backend,
            metadata: metadata,
            support: support,
            estimate: estimate,
            safeBudgetGB: host.safeBudgetGB,
            contextTokens: contextTokens
        )
        let confidence = confidenceFor(metadata: metadata, backend: backend, offline: offline)

        var notes = metadata.notes + support.notes + estimate.notes
        notes.append("Result is heuristic, not a guarantee.")
        if backend == .gguf, metadata.selectedGGUFFile != nil {
            notes.append("GGUF support currently routes through llama.cpp.")
        }

        var warnings = host.warnings + metadata.warnings + support.warnings
        if strict, (metadata.parameterCountB == nil || metadata.effectiveBits == nil || metadata.architecture == .unknown) {
            warnings.append("Strict mode requires complete enough metadata for a positive verdict.")
        }

        return ModelCheckResult(
            model: metadata.displayName,
            backend: backend,
            backendLabel: support.backendLabel,
            format: metadata.format,
            architecture: metadata.architecture,
            parameterCountB: metadata.parameterCountB,
            quantization: metadata.quantization,
            selectedVariant: metadata.selectedVariant,
            availableVariants: metadata.availableVariants,
            effectiveBits: metadata.effectiveBits,
            contextTokens: contextTokens,
            estimatedWeightsGB: estimate.weightsGB ?? metadata.estimatedWeightsGB,
            estimatedRuntimeGB: estimate.runtimeGB,
            safeLocalBudgetGB: host.safeBudgetGB,
            verdict: verdict,
            confidence: confidence,
            notes: unique(notes),
            warnings: unique(warnings),
            host: host,
            metadata: metadata
        )
    }

    private func selectVerdict(
        strict: Bool,
        backend: BackendKind?,
        metadata: ModelMetadata,
        support: ModelSupportAssessment,
        estimate: ModelMemoryEstimate,
        safeBudgetGB: Double?,
        contextTokens: Int
    ) -> ModelCheckVerdict {
        guard backend != nil else {
            return .unknown
        }
        guard support.isFormatSupported else {
            return .unsupportedFormat
        }
        guard support.isArchitectureSupported else {
            return .unsupportedArchitecture
        }

        if strict && (metadata.parameterCountB == nil || metadata.effectiveBits == nil || metadata.architecture == .unknown) {
            return .unknown
        }

        guard let runtimeGB = estimate.runtimeGB, let safeBudgetGB else {
            return .supportedButMetadataIncomplete
        }

        if runtimeGB > safeBudgetGB {
            return .insufficientMemory
        }

        let headroom = safeBudgetGB - runtimeGB
        if contextTokens > 8192 && headroom < max(2.0, runtimeGB * 0.12) {
            return .supportedButContextLimited
        }
        if headroom < max(2.0, runtimeGB * 0.15) {
            return .supportedButTight
        }
        if metadata.parameterCountB == nil || metadata.effectiveBits == nil || metadata.architecture == .unknown {
            return .supportedButMetadataIncomplete
        }
        return .supportedAndLikelyFits
    }

    private func confidenceFor(metadata: ModelMetadata, backend: BackendKind?, offline: Bool) -> Double {
        var score = 0.35
        if backend != nil { score += 0.2 }
        if metadata.architecture != .unknown { score += 0.15 }
        if metadata.parameterCountB != nil { score += 0.1 }
        if metadata.effectiveBits != nil { score += 0.1 }
        if !offline { score += 0.1 }
        return min(1.0, score)
    }

    private func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
