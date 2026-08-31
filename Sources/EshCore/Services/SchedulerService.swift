import Foundation

/// Adaptive Intelligence Scheduler v1 (M9). Turns a `CapabilityRequest` into a concrete, rationale-
/// backed `SchedulerDecision` by combining: installed models + their capabilities, per-model fit on
/// this Mac, and M1 optimizer evidence. Records WHY it chose what it did. Falls back to a *suggestion*
/// (Apple Intelligence, or "install a model") when nothing fits — never silently substitutes.
///
/// Note: "currently-resident models / live memory pressure" is a Warm-Pool (M7) input; v1 takes it
/// as a parameter (default: none), so the scheduler is honest about what it did and did not consider.
public struct SchedulerService: Sendable {
    private let registry: RecommendedModelRegistry
    private let fitService: ModelFitService

    public init(registry: RecommendedModelRegistry = .init(), fitService: ModelFitService = .init()) {
        self.registry = registry
        self.fitService = fitService
    }

    private struct Candidate {
        let install: ModelInstall
        let capabilities: [RecommendedModel.Capability]
        let paramB: Double
        let fit: ModelFitAssessment
        let warm: Bool
    }

    /// Convenience: read installed models + Apple availability from the environment.
    public func decide(request: CapabilityRequest, root: PersistenceRoot, host: HostMachineProfile) -> SchedulerDecision {
        let installs = (try? FileModelStore(root: root).listInstalls()) ?? []
        let apple = AppleIntelligenceService().status().available
        return decide(request: request, installs: installs, host: host, root: root, appleAvailable: apple, otherResidentGB: 0)
    }

    public func decide(
        request: CapabilityRequest,
        installs: [ModelInstall],
        host: HostMachineProfile,
        root: PersistenceRoot,
        appleAvailable: Bool,
        otherResidentGB: Double = 0,
        warmModelIDs: Set<String> = []
    ) -> SchedulerDecision {
        var rationale: [String] = []
        var warnings: [String] = []
        let context = request.expectedContextTokens ?? defaultContext(for: request.goal)

        let candidates = installs.map { install -> Candidate in
            let caps = capabilities(for: install)
            let paramB = parameterCount(for: install)
            let fitInput = ModelFitService.Input(
                parameterCountB: paramB,
                effectiveBits: effectiveBits(for: install),
                format: install.spec.backend == .gguf ? .gguf : .mlx,
                backend: install.spec.backend,
                contextTokens: context,
                diskRequiredBytes: nil,
                otherResidentGB: otherResidentGB
            )
            return Candidate(install: install, capabilities: caps, paramB: paramB,
                             fit: fitService.assess(input: fitInput, host: host, root: root),
                             warm: warmModelIDs.contains(install.id))
        }

        let required = requiredCapabilities(for: request)
        let eligible = candidates.filter { c in
            guard c.fit.fitClass != .unsupported else { return false }
            return required.allSatisfy { c.capabilities.contains($0) }
        }

        rationale.append("request: \(request.goal.rawValue) · quality \(request.quality.rawValue) · latency \(request.latency.rawValue) · context ~\(context)\(request.toolCallingRequired ? " · tools" : "")\(request.visionRequired ? " · vision" : "")")
        rationale.append("\(candidates.count) installed model(s); \(eligible.count) satisfy the required capabilities and fit constraints")

        guard let chosen = rank(eligible, request: request).first else {
            return noModelDecision(request: request, appleAvailable: appleAvailable,
                                   candidatesConsidered: candidates.count, rationale: &rationale, warnings: &warnings)
        }

        // Performance mode from quality/latency, tightened for memory pressure.
        var mode = performanceMode(for: request)
        if chosen.fit.fitClass == .tight || chosen.fit.fitClass == .unlikely {
            mode = .memory
            rationale.append("chosen model is '\(chosen.fit.fitClass.rawValue)' on this Mac — using memory mode to reduce pressure")
        }

        let planner = OptimizationPlanner(store: OptimizationProfileStore(root: root))
        let optContext = OptimizationContext(backend: chosen.install.spec.backend, modelID: chosen.install.id,
                                             runtimeVersion: chosen.install.runtimeVersion, host: host)
        let profile = planner.plan(context: optContext, workload: workload(for: request.goal), contextTokens: context, mode: mode)

        rationale.append("selected \(chosen.install.id) [\(chosen.install.spec.backend.rawValue)] — fit \(chosen.fit.fitClass.rawValue), ~\(chosen.paramB.clean)B params")
        if chosen.warm { rationale.append("already warm (resident) — answers immediately with no load latency") }
        rationale.append("optimization: \(profile.summaryLine)\(profile.evidenceBacked ? " (evidence-backed)" : "")")
        if !profile.evidenceBacked {
            rationale.append("no local benchmark evidence yet — run `esh optimize benchmark \(chosen.install.id)` to let the scheduler use measured strategies")
        }
        if chosen.fit.fitClass == .tight { warnings.append("selected model is a tight fit; expect memory pressure") }

        return SchedulerDecision(
            selectedModelID: chosen.install.id,
            backend: chosen.install.spec.backend,
            performanceMode: mode,
            executionProfile: profile,
            fitClass: chosen.fit.fitClass.rawValue,
            estimatedPeakMemoryGB: chosen.fit.estimatedPeakMemoryGB,
            appleIntelligenceSuggested: false,
            evidenceBacked: profile.evidenceBacked,
            candidatesConsidered: candidates.count,
            rationale: rationale,
            warnings: warnings
        )
    }

    // MARK: - Ranking

    private func rank(_ candidates: [Candidate], request: CapabilityRequest) -> [Candidate] {
        candidates.sorted { score($0, request: request) > score($1, request: request) }
    }

    private func score(_ c: Candidate, request: CapabilityRequest) -> Double {
        var s = Double(fitRank(c.fit.fitClass)) * 100     // avoid OOM first (dominant term)
        let mem = c.fit.estimatedPeakMemoryGB ?? c.paramB
        switch request.quality {
        case .fast: s -= mem                               // smaller = faster/lighter
        case .high, .balanced: s += mem                    // larger = better quality (that still fits)
        }
        // M7: an already-warm model can answer immediately — prefer it on close calls. The bonus is
        // deliberately small (a few GB of quality-size advantage in a cold model still wins).
        if c.warm { s += 10 }
        return s
    }

    private func fitRank(_ fit: ModelFitClass) -> Int {
        switch fit {
        case .comfortable: return 4
        case .fits: return 3
        case .unknown: return 2
        case .tight: return 1
        case .unlikely: return 0
        case .unsupported: return -1
        }
    }

    // MARK: - No-model fallback (suggestion only)

    private func noModelDecision(request: CapabilityRequest, appleAvailable: Bool, candidatesConsidered: Int,
                                 rationale: inout [String], warnings: inout [String]) -> SchedulerDecision {
        let modestForApple = !request.toolCallingRequired && !request.visionRequired
            && (request.goal == .general || request.goal == .coding)
        if appleAvailable && modestForApple {
            rationale.append("no installed model satisfies the request; Apple Intelligence is available and can handle this on-device with zero downloads")
            warnings.append("this is a suggestion — esh will not use Apple Intelligence in place of a model you explicitly request")
            return SchedulerDecision(appleIntelligenceSuggested: true, candidatesConsidered: candidatesConsidered,
                                     rationale: rationale, warnings: warnings)
        }
        rationale.append("no installed model satisfies the request; install one with `esh model recommended --for-this-mac`")
        if request.toolCallingRequired { rationale.append("tool-calling was required, which Apple Intelligence does not cover here") }
        warnings.append("no suitable local model available")
        return SchedulerDecision(candidatesConsidered: candidatesConsidered, rationale: rationale, warnings: warnings)
    }

    // MARK: - Helpers

    private func requiredCapabilities(for request: CapabilityRequest) -> [RecommendedModel.Capability] {
        var caps: [RecommendedModel.Capability] = []
        switch request.goal {
        case .coding: caps.append(.coding)
        case .reasoning: caps.append(.reasoning)
        case .general, .structured: caps.append(.chat)
        }
        if request.toolCallingRequired { caps.append(.toolCalling) }
        if request.visionRequired { caps.append(.vision) }
        return caps
    }

    private func performanceMode(for request: CapabilityRequest) -> PerformanceMode {
        switch request.quality {
        case .fast: return .speed
        case .high: return .auto
        case .balanced: return .balanced
        }
    }

    private func workload(for goal: CapabilityRequest.Goal) -> OptimizationWorkload {
        switch goal {
        case .general: return .chat
        case .coding: return .coding
        case .reasoning: return .reasoning
        case .structured: return .structured
        }
    }

    private func defaultContext(for goal: CapabilityRequest.Goal) -> Int {
        switch goal {
        case .reasoning: return 8192
        case .coding: return 8192
        default: return 4096
        }
    }

    /// Capabilities for an installed model: catalog metadata if known, else name heuristics.
    func capabilities(for install: ModelInstall) -> [RecommendedModel.Capability] {
        let ref = install.spec.source.reference.lowercased()
        if let rec = registry.list().first(where: { $0.repoID.lowercased() == ref || $0.id.lowercased() == install.id.lowercased() }) {
            return rec.capabilities
        }
        let features = Set(ModelFeatureClassifier.features(for: install))
        var caps: [RecommendedModel.Capability] = [.chat]
        if features.contains("code") { caps.append(.coding) }
        if features.contains("reason") { caps.append(.reasoning) }
        if features.contains("vision") { caps.append(.vision) }
        return caps
    }

    private func parameterCount(for install: ModelInstall) -> Double {
        let ref = install.spec.source.reference.lowercased()
        if let rec = registry.list().first(where: { $0.repoID.lowercased() == ref || $0.id.lowercased() == install.id.lowercased() }),
           let p = ModelFitService.parseParameterCount(rec.parameterSize) {
            return p
        }
        // Estimate from on-disk weight bytes and assumed bit-width: params ≈ GB * 8 / bits.
        let gib = Double(install.sizeBytes) / 1_073_741_824
        let bits = effectiveBits(for: install)
        guard gib > 0, bits > 0 else { return 7 } // conservative default
        return max(0.1, gib * 8 / bits)
    }

    private func effectiveBits(for install: ModelInstall) -> Double {
        let ref = install.spec.source.reference.lowercased()
        if let rec = registry.list().first(where: { $0.repoID.lowercased() == ref || $0.id.lowercased() == install.id.lowercased() }),
           let b = ModelFitService.parseEffectiveBits(rec.quantization) {
            return b
        }
        return 4.5
    }
}

private extension Double {
    var clean: String { self == rounded() ? String(Int(self)) : String(format: "%.1f", self) }
}
