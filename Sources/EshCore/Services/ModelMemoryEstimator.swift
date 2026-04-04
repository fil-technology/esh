import Foundation

public struct ModelMemoryEstimate: Hashable, Sendable {
    public var weightsGB: Double?
    public var runtimeGB: Double?
    public var notes: [String]

    public init(weightsGB: Double?, runtimeGB: Double?, notes: [String] = []) {
        self.weightsGB = weightsGB
        self.runtimeGB = runtimeGB
        self.notes = notes
    }
}

public struct ModelMemoryEstimator: Sendable {
    public init() {}

    public func estimate(
        parameterCountB: Double?,
        effectiveBits: Double?,
        quantization: String?,
        contextTokens: Int,
        format: ModelFormat
    ) -> ModelMemoryEstimate {
        guard let parameterCountB, let effectiveBits else {
            return ModelMemoryEstimate(
                weightsGB: nil,
                runtimeGB: nil,
                notes: ["Memory estimate is incomplete because parameter count or quantization could not be inferred."]
            )
        }

        let weightsGB = parameterCountB * (effectiveBits / 8)
        let contextGB = contextOverheadGB(contextTokens: contextTokens, parameterCountB: parameterCountB, format: format)
        let safetyMultiplier = format == .gguf ? 1.18 : 1.22
        let runtimeGB = (weightsGB * safetyMultiplier) + contextGB

        return ModelMemoryEstimate(
            weightsGB: round1(weightsGB),
            runtimeGB: round1(runtimeGB),
            notes: contextGB > 0.25 ? ["Longer context increases runtime memory pressure."] : []
        )
    }

    private func contextOverheadGB(contextTokens: Int, parameterCountB: Double, format: ModelFormat) -> Double {
        let normalizedContext = Double(max(0, contextTokens - 4096)) / 4096
        guard normalizedContext > 0 else { return 0 }
        let multiplier = format == .gguf ? 0.12 : 0.16
        return normalizedContext * max(0.5, parameterCountB * multiplier)
    }

    private func round1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }
}
