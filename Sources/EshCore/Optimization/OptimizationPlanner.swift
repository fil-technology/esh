import Foundation

/// Turns a request (model/backend/workload/context/mode) into a validated `ExecutionProfile`.
///
/// Core rule: **no strategy enters `auto` without local measured evidence that meets the quality
/// threshold.** With no evidence, `auto` falls back to conservative known-good baselines. The
/// explicit `speed`/`memory` modes may apply preference-appropriate strategies more assertively,
/// but always record honest rationale (and never claim evidence that does not exist).
public struct OptimizationPlanner: Sendable {
    private let registry: OptimizationStrategyRegistry
    private let store: OptimizationProfileStore?
    /// Minimum quality proxy (0...1) a quality-changing strategy must meet to be auto-selected.
    private let qualityThreshold: Double

    public init(
        registry: OptimizationStrategyRegistry = OptimizationStrategyRegistry(),
        store: OptimizationProfileStore? = nil,
        qualityThreshold: Double = 0.85
    ) {
        self.registry = registry
        self.store = store
        self.qualityThreshold = qualityThreshold
    }

    public func plan(
        context: OptimizationContext,
        workload: OptimizationWorkload,
        contextTokens: Int?,
        mode: PerformanceMode
    ) -> ExecutionProfile {
        var selections: [String: String] = [:]
        var reasons: [String] = []
        var evidenceBacked = false
        let bucket = contextTokens.map(ContextBucket.init(tokens:))
        let key = profileKey(context: context)
        let hasEvidence = store?.hasEvidence(for: key) ?? false

        // --- KV cache ---
        if registry.compatibleStrategies(category: .kvCache, context: context).isEmpty == false {
            let (id, reason, evidence) = planKVCache(
                context: context, workload: workload, bucket: bucket, mode: mode, key: key
            )
            selections[OptimizationCategory.kvCache.rawValue] = id
            reasons.append(reason)
            evidenceBacked = evidenceBacked || evidence
        }

        // --- Prompt / prefix cache ---
        if registry.compatibleStrategies(category: .promptCache, context: context).isEmpty == false {
            let baseline = OptimizationStrategyRegistry.promptReuse.id
            if mode == .memory, workload != .agentPrefix {
                selections[OptimizationCategory.promptCache.rawValue] = OptimizationStrategyRegistry.promptOff.id
                reasons.append("memory mode disables prompt-cache reuse to reduce resident memory")
            } else {
                selections[OptimizationCategory.promptCache.rawValue] = baseline
                reasons.append(workload == .agentPrefix
                    ? "agent/prefix workload reuses the prompt cache to skip re-prefill (distribution-equivalent)"
                    : "prompt-cache reuse is safe (distribution-equivalent) and speeds repeated prefixes")
            }
        }

        if !hasEvidence {
            reasons.append("no local benchmark evidence for this model/hardware yet — run `esh optimize benchmark \(context.modelID)` to let `auto` use measured strategies")
        }

        return ExecutionProfile(
            backend: context.backend,
            model: context.modelID,
            performanceMode: mode,
            workload: workload,
            contextTokens: contextTokens,
            selections: selections,
            reasons: reasons,
            evidenceBacked: evidenceBacked,
            benchmarkProfileVersion: hasEvidence ? OptimizationSchema.version : nil
        )
    }

    // MARK: - KV cache decision

    private func planKVCache(
        context: OptimizationContext,
        workload: OptimizationWorkload,
        bucket: ContextBucket?,
        mode: PerformanceMode,
        key: OptimizationProfileKey
    ) -> (id: String, reason: String, evidence: Bool) {
        let baseline = OptimizationStrategyRegistry.kvRaw.id

        // Evidence-driven pick (auto/balanced can only escalate with evidence).
        if let store, let bucket {
            if let best = bestEvidenceStrategy(category: .kvCache, key: key, workload: workload, bucket: bucket, mode: mode, store: store),
               best.strategyID != baseline {
                return (best.strategyID, "\(best.strategyID) selected from local benchmark evidence (\(best.rationale))", true)
            }
        }

        switch mode {
        case .memory:
            // User explicitly prefers memory: apply a memory-saving KV strategy for larger contexts.
            let big = (bucket == .long || bucket == .xlong || bucket == .xxlong)
            if big, registry.compatibleStrategies(category: .kvCache, context: context).contains(where: { $0.id == OptimizationStrategyRegistry.kvTurbo.id }) {
                return (OptimizationStrategyRegistry.kvTurbo.id,
                        "memory mode prefers TurboQuant KV for \(bucket?.rawValue ?? "long") context to cut KV memory (~45%); no local quality evidence yet — validate with `esh optimize benchmark`",
                        false)
            }
            return (baseline, "memory mode: context is small enough that full-precision KV is already cheap", false)
        case .speed, .balanced, .auto:
            return (baseline, mode == .auto
                ? "auto: no validated non-baseline KV strategy for this workload/context, using full-precision KV"
                : "\(mode.rawValue) mode uses full-precision KV (no validated faster alternative for this workload)", false)
        }
    }

    /// Choose the best evidence-backed strategy for a category under the mode's objective, subject
    /// to the quality threshold.
    private func bestEvidenceStrategy(
        category: OptimizationCategory,
        key: OptimizationProfileKey,
        workload: OptimizationWorkload,
        bucket: ContextBucket,
        mode: PerformanceMode,
        store: OptimizationProfileStore
    ) -> (strategyID: String, rationale: String)? {
        let results = store.results(for: key, workload: workload, context: bucket)
            .filter { $0.category == category }
        guard !results.isEmpty else { return nil }

        // Quality gate: a quality-changing strategy must meet the threshold.
        func passesQuality(_ r: OptimizationBenchmarkResult) -> Bool {
            guard let strategy = registry.strategy(id: r.strategyID) else { return false }
            if strategy.distributionEquivalent { return true }
            if let q = r.median.qualityScore { return q >= qualityThreshold }
            if r.median.distributionEquivalentToBaseline == true { return true }
            return false // quality-changing strategy with no quality measurement is NOT auto-eligible
        }

        // The quality floor applies to EVERY mode: speed/memory still respect a minimum
        // quality/correctness constraint, they only differ in the objective they optimize.
        let eligible = results.filter { r in
            r.median.errorCount == 0 && passesQuality(r)
        }
        guard !eligible.isEmpty else { return nil }

        let best: OptimizationBenchmarkResult?
        switch mode {
        case .speed, .auto, .balanced:
            best = eligible.max { ($0.median.decodeTokensPerSec ?? 0) < ($1.median.decodeTokensPerSec ?? 0) }
        case .memory:
            best = eligible.min { ($0.median.peakMemoryBytes ?? .max) < ($1.median.peakMemoryBytes ?? .max) }
        }
        guard let winner = best else { return nil }
        let metric: String
        switch mode {
        case .memory: metric = winner.median.peakMemoryBytes.map { "peak \(ByteFormatting.string(for: $0))" } ?? "lowest measured memory"
        default: metric = winner.median.decodeTokensPerSec.map { String(format: "%.1f tok/s decode", $0) } ?? "fastest measured"
        }
        return (winner.strategyID, metric)
    }

    public func profileKey(context: OptimizationContext) -> OptimizationProfileKey {
        OptimizationProfileKey(
            hardwareFingerprint: OptimizationProfileKey.hardwareFingerprint(from: context.host),
            modelID: context.modelID,
            backend: context.backend.rawValue,
            runtimeVersion: context.runtimeVersion
        )
    }
}
