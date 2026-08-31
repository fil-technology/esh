import Foundation

/// Produces profile-specific, fit-aware, local-evidence-aware model recommendations for this Mac —
/// the Benchmark Lab's recommendation output. It reuses the model catalog (metadata), Model Fit
/// (hardware fit), and the M1 optimization profile store (local measured evidence). It NEVER invents
/// quality numbers: an entry is `estimated` (fit/capability-derived) unless the user has actually
/// benchmarked the model locally, in which case measured decode speed is attached and it is marked
/// `measured-local`. Local measurements supersede generic ranking for that Mac.
public struct ModelRecommendationService: Sendable {
    public static let scoringVersion = 1
    public static let datasetVersion = 1

    private let registry: RecommendedModelRegistry
    private let fitService: ModelFitService

    public init(registry: RecommendedModelRegistry = .init(), fitService: ModelFitService = .init()) {
        self.registry = registry
        self.fitService = fitService
    }

    public func recommend(
        profile: RecommendationProfile,
        host: HostMachineProfile,
        root: PersistenceRoot,
        limit: Int = 3,
        includeTight: Bool = true
    ) -> [CuratedRecommendation] {
        let hwClass = HardwareClass(totalMemoryGB: host.totalMemoryGB ?? 16)
        let context = contextFor(profile)
        let store = OptimizationProfileStore(root: root)
        // Local measured evidence from the Model Benchmark Lab (perf + deterministic quality), keyed by
        // install id. Consulted alongside the M1 optimization profile store — one recommendation
        // engine, two evidence sources; not a duplicate benchmark system.
        let labDataset = ModelBenchmarkLabStore(root: root).load()
        // Map each catalog repoID -> installed model id(s), so local benchmark evidence (keyed by
        // install id) can be matched back to a catalog recommendation.
        let installs = (try? FileModelStore(root: root).listInstalls()) ?? []
        var installIDsByRepo: [String: [String]] = [:]
        for install in installs {
            installIDsByRepo[install.spec.source.reference.lowercased(), default: []].append(install.id)
        }

        struct Scored {
            let model: RecommendedModel
            let fit: ModelFitAssessment
            let localTPS: Double?
            let labEvidence: ModelBenchmarkEvidence?
            let score: Double
        }

        let candidates: [Scored] = registry.list().compactMap { model in
            guard matches(profile: profile, model: model) else { return nil }
            let fit = fitService.assess(recommendedModel: model, contextTokens: context, host: host, root: root)
            if fit.fitClass == .unsupported { return nil }
            if fit.fitClass == .unlikely { return nil }                 // discoverable elsewhere, not recommended
            if fit.fitClass == .tight && !includeTight && profile != .bestQuality { return nil }
            let installIDs = installIDsByRepo[model.repoID.lowercased()] ?? []
            let lab = installIDs.compactMap { labDataset.evidence(for: $0) }.first
            // Prefer optimization-store TPS; fall back to the lab's measured decode TPS.
            let localTPS = localDecodeTPS(installIDs: installIDs, store: store)
                ?? lab?.performance.decodeTokensPerSecondMedian
            let score = score(profile: profile, model: model, fit: fit, localTPS: localTPS)
            return Scored(model: model, fit: fit, localTPS: localTPS, labEvidence: lab, score: score)
        }

        let ranked = candidates.sorted { $0.score > $1.score }.prefix(limit)
        return ranked.enumerated().map { index, s in
            let evidence: RecommendationEvidence = (s.localTPS != nil || s.labEvidence != nil) ? .measuredLocal : .estimated
            var reasons = [profileReason(profile, model: s.model, fit: s.fit)]
            if let tps = s.localTPS { reasons.append(String(format: "your local benchmark: ~%.1f tok/s decode", tps)) }
            if let lab = s.labEvidence {
                reasons.append("benchmark lab: quality \(lab.quality.passed)/\(lab.quality.total) measured on your Mac")
            }
            reasons.append("fit: \(s.fit.fitClass.rawValue) on this \(hwClass.displayName) Mac")
            return CuratedRecommendation(
                modelID: s.model.id, repoID: s.model.repoID, backend: s.model.backend,
                hardwareClass: hwClass, profile: profile, rank: index + 1,
                fit: s.fit.fitClass.rawValue, evidence: evidence,
                medianDecodeTPS: s.localTPS,
                peakMemoryGB: s.fit.estimatedPeakMemoryGB,
                maxRecommendedContext: s.fit.recommendedContext ?? s.model.contextWindow,
                reasons: reasons
            )
        }
    }

    /// The full versioned dataset for this Mac (all profiles), consumable by onboarding / tooling.
    public func dataset(host: HostMachineProfile, root: PersistenceRoot, now: String? = nil) -> CuratedRecommendationDataset {
        let recs = RecommendationProfile.allCases.flatMap { recommend(profile: $0, host: host, root: root, limit: 3) }
        return CuratedRecommendationDataset(
            datasetVersion: Self.datasetVersion, scoringVersion: Self.scoringVersion,
            generatedAtISO8601: now, recommendations: recs
        )
    }

    // MARK: - Matching & scoring

    private func matches(profile: RecommendationProfile, model: RecommendedModel) -> Bool {
        switch profile {
        case .coding: return model.capabilities.contains(.coding)
        case .reasoning: return model.capabilities.contains(.reasoning)
        case .tools: return model.capabilities.contains(.toolCalling)
        case .longContext: return (model.contextWindow ?? 0) >= 32768 && model.capabilities.contains(.chat)
        case .general, .fast, .lowMemory, .bestQuality: return model.capabilities.contains(.chat)
        }
    }

    private func contextFor(_ profile: RecommendationProfile) -> Int {
        switch profile {
        case .longContext: return 32768
        case .reasoning, .coding: return 8192
        default: return 4096
        }
    }

    /// Transparent, versioned scoring. Higher is better. Combines fit headroom with a profile-
    /// appropriate size preference and any local measured speed. No fabricated precision.
    private func score(profile: RecommendationProfile, model: RecommendedModel, fit: ModelFitAssessment, localTPS: Double?) -> Double {
        let fitScore: Double
        switch fit.fitClass {
        case .comfortable: fitScore = 3
        case .fits: fitScore = 2
        case .unknown: fitScore = 1.5
        case .tight: fitScore = 0.5
        default: fitScore = 0
        }
        let mem = fit.estimatedPeakMemoryGB ?? 8
        let sizePref: Double
        switch profile {
        case .fast, .lowMemory:
            sizePref = -mem                       // smaller/lighter preferred
        case .bestQuality, .coding, .reasoning:
            sizePref = mem                        // bigger-that-fits preferred (quality proxy)
        case .general, .tools, .longContext:
            sizePref = mem * 0.5                  // moderate preference for capable-but-fitting
        }
        // Local measured speed is a real bonus when present (personalization).
        let speedBonus = localTPS.map { min(5, $0 / 20) } ?? 0
        return fitScore * 10 + sizePref + speedBonus
    }

    private func profileReason(_ profile: RecommendationProfile, model: RecommendedModel, fit: ModelFitAssessment) -> String {
        switch profile {
        case .coding: return "coding-capable (\(model.parameterSize), \(model.contextHint) ctx)"
        case .reasoning: return "reasoning-capable (\(model.parameterSize))"
        case .tools: return "supports tool calling (\(model.parameterSize))"
        case .fast: return "small/fast (\(model.parameterSize), ~\(String(format: "%.1f", fit.estimatedPeakMemoryGB ?? 0)) GB)"
        case .lowMemory: return "low memory footprint (~\(String(format: "%.1f", fit.estimatedPeakMemoryGB ?? 0)) GB peak)"
        case .longContext: return "long context (\(model.contextHint))"
        case .bestQuality: return "largest quality-tier model that still fits (\(model.parameterSize))"
        case .general: return "balanced general assistant (\(model.parameterSize))"
        }
    }

    /// Local measured decode tok/s for this model on this Mac, if the M1 harness has benchmarked an
    /// installed copy of it. Keyed by install id (benchmarks) resolved from the catalog repoID.
    private func localDecodeTPS(installIDs: [String], store: OptimizationProfileStore) -> Double? {
        guard !installIDs.isEmpty else { return nil }
        let idSet = Set(installIDs)
        let all = store.allResults().filter { idSet.contains($0.key.modelID) && $0.strategyID == OptimizationStrategyRegistry.kvRaw.id }
        let tps = all.compactMap { $0.median.decodeTokensPerSec }
        guard !tps.isEmpty else { return nil }
        return tps.reduce(0, +) / Double(tps.count)
    }
}
