import Foundation

/// Registry of optimization strategies. Built-in strategies represent esh's *existing* behavior
/// behind the boundary (KV-cache modes incl. TurboQuant, and the prompt/prefix cache). Adding a
/// future optimizer means registering another `OptimizationStrategy`, not editing inference code.
public struct OptimizationStrategyRegistry: Sendable {
    private let strategies: [OptimizationStrategy]

    public init(strategies: [OptimizationStrategy] = OptimizationStrategyRegistry.builtIn) {
        self.strategies = strategies
    }

    public var all: [OptimizationStrategy] { strategies }

    public func strategy(id: String) -> OptimizationStrategy? {
        strategies.first { $0.id == id }
    }

    public func strategies(in category: OptimizationCategory) -> [OptimizationStrategy] {
        strategies.filter { $0.category == category }
    }

    public func baseline(for category: OptimizationCategory) -> OptimizationStrategy? {
        strategies.first { $0.category == category && $0.isBaseline }
    }

    /// Categories that have at least one strategy applicable to the given context.
    public func applicableCategories(for context: OptimizationContext) -> [OptimizationCategory] {
        OptimizationCategory.allCases.filter { category in
            strategies(in: category).contains { compatibility(of: $0, in: context).isCompatible }
        }
    }

    /// Strategies in `category` compatible with the given context.
    public func compatibleStrategies(
        category: OptimizationCategory,
        context: OptimizationContext
    ) -> [OptimizationStrategy] {
        strategies(in: category).filter { compatibility(of: $0, in: context).isCompatible }
    }

    public func compatibility(
        of strategy: OptimizationStrategy,
        in context: OptimizationContext
    ) -> OptimizationCompatibility {
        if !strategy.backends.contains(context.backend) {
            return .incompatible(reason: "\(strategy.id) does not support the \(context.backend.rawValue) backend")
        }
        if let families = strategy.modelFamilies, let family = context.modelFamily,
           !families.contains(where: { family.lowercased().contains($0.lowercased()) }) {
            return .incompatible(reason: "\(strategy.id) is limited to model families \(families.joined(separator: ", "))")
        }
        if let minVersion = strategy.minRuntimeVersion, let runtime = context.runtimeVersion,
           SemanticVersionCompare.isOlder(runtime, than: minVersion) {
            return .incompatible(reason: "\(strategy.id) requires runtime >= \(minVersion) (found \(runtime))")
        }
        return .compatible
    }

    // MARK: - Built-in strategies

    // KV-cache family (maps to esh CacheMode + MLX KV quant behavior).
    public static let kvRaw = OptimizationStrategy(
        id: "kv.raw",
        category: .kvCache,
        displayName: "Full-precision KV cache",
        summary: "Uncompressed fp16 KV cache. Highest fidelity, highest memory.",
        backends: [.mlx, .gguf],
        distributionEquivalent: true,
        estimatedMemoryDeltaRatio: 0,
        isBaseline: true
    )
    public static let kvTurbo = OptimizationStrategy(
        id: "kv.turbo",
        category: .kvCache,
        displayName: "TurboQuant KV cache",
        summary: "TurboQuant-compressed KV cache. Lower memory for long context; quality is family-sensitive so it must be benchmarked before auto.",
        backends: [.mlx],
        qualityMayChange: true,
        estimatedMemoryDeltaRatio: -0.45,
        requiresBenchmarkBeforeAuto: true
    )
    public static let kvTriAttention = OptimizationStrategy(
        id: "kv.triattention",
        category: .kvCache,
        displayName: "TriAttention KV cache",
        summary: "Calibrated TriAttention KV packaging. Requires a model calibration; benchmark before auto.",
        backends: [.mlx],
        qualityMayChange: true,
        estimatedMemoryDeltaRatio: -0.30,
        requiresBenchmarkBeforeAuto: true,
        experimental: true
    )

    // Prompt/prefix cache family (maps to esh CacheService reuse).
    public static let promptReuse = OptimizationStrategy(
        id: "prompt.reuse",
        category: .promptCache,
        displayName: "Reuse prompt cache when valid",
        summary: "Reuse a previously built prompt/prefix cache when the prefix matches. Speeds repeated large-prefix (agent) workloads.",
        backends: [.mlx],
        distributionEquivalent: true,
        isBaseline: true
    )
    public static let promptOff = OptimizationStrategy(
        id: "prompt.off",
        category: .promptCache,
        displayName: "No prompt cache",
        summary: "Never reuse a prompt cache. Lowest memory, no prefill reuse.",
        backends: [.mlx, .gguf],
        distributionEquivalent: true,
        estimatedMemoryDeltaRatio: 0
    )

    /// Placeholder descriptor for the next optimizer family. Declared so `strategies` can advertise
    /// it as a known-but-unimplemented candidate; never selected by the planner (no backend
    /// supports it yet), proving new families slot in without touching orchestration.
    public static let speculativeDraft = OptimizationStrategy(
        id: "spec.draft",
        category: .speculativeDecoding,
        displayName: "Speculative decoding (draft model)",
        summary: "Candidate: draft-model speculative decoding. Not yet wired to a backend; listed as a future strategy.",
        backends: [], // no backend support yet -> never compatible/selected
        qualityMayChange: false,
        distributionEquivalent: true,
        estimatedMemoryDeltaRatio: 0.25,
        requiresBenchmarkBeforeAuto: true,
        experimental: true
    )

    public static let builtIn: [OptimizationStrategy] = [
        kvRaw, kvTurbo, kvTriAttention,
        promptReuse, promptOff,
        speculativeDraft
    ]
}

/// Minimal dotted-version comparison for runtime-constraint checks (e.g. "2.31.3" vs "2.31.0").
enum SemanticVersionCompare {
    static func isOlder(_ lhs: String, than rhs: String) -> Bool {
        let l = numericComponents(lhs)
        let r = numericComponents(rhs)
        for i in 0..<max(l.count, r.count) {
            let a = i < l.count ? l[i] : 0
            let b = i < r.count ? r[i] : 0
            if a != b { return a < b }
        }
        return false
    }

    private static func numericComponents(_ version: String) -> [Int] {
        version.split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
    }
}
