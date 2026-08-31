import Foundation
import Testing
@testable import EshCore

@Suite
struct OptimizationStrategyTests {
    @Test
    func kvStrategiesRespectBackendSupport() {
        let registry = OptimizationStrategyRegistry()
        let mlx = OptimizationContext(backend: .mlx, modelID: "m")
        let gguf = OptimizationContext(backend: .gguf, modelID: "m")
        #expect(registry.compatibility(of: OptimizationStrategyRegistry.kvTurbo, in: mlx).isCompatible)
        #expect(!registry.compatibility(of: OptimizationStrategyRegistry.kvTurbo, in: gguf).isCompatible)
        // The future speculative strategy has no backend yet -> never compatible.
        #expect(!registry.compatibility(of: OptimizationStrategyRegistry.speculativeDraft, in: mlx).isCompatible)
    }

    @Test
    func runtimeVersionConstraintIsEnforced() {
        let strategy = OptimizationStrategy(id: "x", category: .kvCache, displayName: "x", summary: "", backends: [.mlx], minRuntimeVersion: "2.31.0")
        let registry = OptimizationStrategyRegistry(strategies: [strategy])
        let old = OptimizationContext(backend: .mlx, modelID: "m", runtimeVersion: "2.30.9")
        let new = OptimizationContext(backend: .mlx, modelID: "m", runtimeVersion: "2.31.3")
        #expect(!registry.compatibility(of: strategy, in: old).isCompatible)
        #expect(registry.compatibility(of: strategy, in: new).isCompatible)
    }
}

@Suite
struct OptimizationPlannerTests {
    private func context() -> OptimizationContext {
        OptimizationContext(backend: .mlx, modelID: "demo", runtimeVersion: "1.0.0",
                            host: HostMachineProfile(chipDescription: "Apple M9", totalMemoryGB: 32, safeBudgetGB: 20))
    }

    @Test
    func autoWithoutEvidenceUsesConservativeBaseline() {
        let planner = OptimizationPlanner(store: nil)
        let profile = planner.plan(context: context(), workload: .coding, contextTokens: 16000, mode: .auto)
        #expect(profile.strategyID(for: .kvCache) == OptimizationStrategyRegistry.kvRaw.id)
        #expect(!profile.evidenceBacked)
        #expect(profile.cacheMode == .raw)
    }

    @Test
    func memoryModeEscalatesForLongContext() {
        let planner = OptimizationPlanner(store: nil)
        let profile = planner.plan(context: context(), workload: .chat, contextTokens: 16000, mode: .memory)
        #expect(profile.strategyID(for: .kvCache) == OptimizationStrategyRegistry.kvTurbo.id)
        // Preference-driven, NOT evidence-backed — must be honestly reported.
        #expect(!profile.evidenceBacked)
        #expect(profile.cacheMode == .turbo)
    }

    @Test
    func autoUsesEvidenceWhenQualityPasses() throws {
        let dir = tempDir()
        let store = OptimizationProfileStore(directoryURL: dir)
        let ctx = context()
        let key = OptimizationPlanner().profileKey(context: ctx)
        // TurboQuant measured faster AND passing quality threshold.
        try store.save(makeResult(key: key, strategyID: OptimizationStrategyRegistry.kvTurbo.id,
                                  workload: .coding, bucket: ContextBucket(tokens: 16000),
                                  decode: 30, quality: 0.95))
        try store.save(makeResult(key: key, strategyID: OptimizationStrategyRegistry.kvRaw.id,
                                  workload: .coding, bucket: ContextBucket(tokens: 16000),
                                  decode: 20, quality: 1.0))
        let planner = OptimizationPlanner(store: store)
        let profile = planner.plan(context: ctx, workload: .coding, contextTokens: 16000, mode: .auto)
        #expect(profile.strategyID(for: .kvCache) == OptimizationStrategyRegistry.kvTurbo.id)
        #expect(profile.evidenceBacked)
    }

    @Test
    func autoRejectsEvidenceThatFailsQuality() throws {
        let dir = tempDir()
        let store = OptimizationProfileStore(directoryURL: dir)
        let ctx = context()
        let key = OptimizationPlanner().profileKey(context: ctx)
        // TurboQuant faster but BELOW the quality threshold -> must NOT be auto-selected.
        try store.save(makeResult(key: key, strategyID: OptimizationStrategyRegistry.kvTurbo.id,
                                  workload: .coding, bucket: ContextBucket(tokens: 16000),
                                  decode: 40, quality: 0.5))
        let planner = OptimizationPlanner(store: store)
        let profile = planner.plan(context: ctx, workload: .coding, contextTokens: 16000, mode: .auto)
        #expect(profile.strategyID(for: .kvCache) == OptimizationStrategyRegistry.kvRaw.id)
    }

    @Test
    func speedModeStillRespectsQualityFloor() throws {
        // A faster strategy that FAILS quality must not be chosen even in speed mode.
        let dir = tempDir()
        let store = OptimizationProfileStore(directoryURL: dir)
        let ctx = context()
        let key = OptimizationPlanner().profileKey(context: ctx)
        try store.save(makeResult(key: key, strategyID: OptimizationStrategyRegistry.kvTriAttention.id,
                                  workload: .chat, bucket: ContextBucket(tokens: 512),
                                  decode: 250, quality: 0.05))   // fast but broken output
        try store.save(makeResult(key: key, strategyID: OptimizationStrategyRegistry.kvRaw.id,
                                  workload: .chat, bucket: ContextBucket(tokens: 512),
                                  decode: 245, quality: 1.0))
        let planner = OptimizationPlanner(store: store)
        let profile = planner.plan(context: ctx, workload: .chat, contextTokens: 512, mode: .speed)
        #expect(profile.strategyID(for: .kvCache) == OptimizationStrategyRegistry.kvRaw.id)
    }

    @Test
    func executionProfileRoundTrips() throws {
        let profile = OptimizationPlanner(store: nil).plan(context: context(), workload: .reasoning, contextTokens: 8000, mode: .balanced)
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ExecutionProfile.self, from: data)
        #expect(decoded == profile)
    }

    private func makeResult(key: OptimizationProfileKey, strategyID: String, workload: OptimizationWorkload, bucket: ContextBucket, decode: Double, quality: Double) -> OptimizationBenchmarkResult {
        OptimizationBenchmarkResult(
            key: key, category: .kvCache, strategyID: strategyID, workload: workload, contextBucket: bucket,
            median: BenchmarkMetrics(decodeTokensPerSec: decode, peakMemoryBytes: 1_000_000, qualityScore: quality, errorCount: 0),
            recordedAtISO8601: "2026-08-31T00:00:00Z"
        )
    }

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@Suite
struct OptimizationProfileStoreTests {
    @Test
    func keyMismatchInvalidatesResults() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = OptimizationProfileStore(directoryURL: dir)
        let key = OptimizationProfileKey(hardwareFingerprint: "M9|32GB", modelID: "m", backend: "mlx", runtimeVersion: "1.0.0")
        let other = OptimizationProfileKey(hardwareFingerprint: "M9|32GB", modelID: "m", backend: "mlx", runtimeVersion: "2.0.0")
        try store.save(OptimizationBenchmarkResult(key: key, category: .kvCache, strategyID: "kv.raw",
            workload: .chat, contextBucket: .short, median: BenchmarkMetrics(), recordedAtISO8601: "t"))
        #expect(store.hasEvidence(for: key))
        #expect(!store.hasEvidence(for: other))       // different runtime version -> not applied
        #expect(store.results(for: key, workload: .chat, context: .short).count == 1)
        #expect(store.results(for: other, workload: nil, context: nil).isEmpty)
    }
}

/// Deterministic runner: baseline "raw" returns a reference string; "turbo" returns a divergent
/// string, so the harness computes a real quality-overlap proxy and equivalence flags.
private struct MockRunner: BenchmarkInferenceRunner {
    func generate(model: String, backend: BackendKind, cacheMode: CacheMode, prompt: String, maxTokens: Int, seed: Int?) async throws -> BenchmarkRunOutput {
        switch cacheMode {
        case .turbo:
            return BenchmarkRunOutput(outputText: "alpha beta different words here", ttftMs: 90, decodeTokensPerSec: 26, memoryBytes: 700_000_000)
        default:
            return BenchmarkRunOutput(outputText: "alpha beta gamma delta epsilon", ttftMs: 100, decodeTokensPerSec: 20, memoryBytes: 1_000_000_000)
        }
    }
}

@Suite
struct BenchmarkHarnessTests {
    @Test
    func harnessRunsStrategiesAndComputesMedians() async {
        let harness = BenchmarkHarness()
        let scenarios = [BenchmarkScenario(name: "s", workload: .chat, approxContextTokens: 512, prompt: "hi", maxTokens: 16)]
        let results = await harness.benchmarkKVCache(
            model: "demo", backend: .mlx, host: HostMachineProfile(chipDescription: "M9", totalMemoryGB: 32),
            runtimeVersion: "1.0.0", scenarios: scenarios, options: .quick, runner: MockRunner(),
            recordedAtISO8601: "2026-08-31T00:00:00Z"
        )
        // Two eligible MLX KV strategies (raw baseline, turbo) benchmarked.
        #expect(results.contains { $0.strategyID == OptimizationStrategyRegistry.kvRaw.id })
        let turbo = results.first { $0.strategyID == OptimizationStrategyRegistry.kvTurbo.id }
        #expect(turbo != nil)
        #expect(turbo?.median.decodeTokensPerSec == 26)
        // Baseline is distribution-equivalent to itself; turbo gets a measured quality proxy < 1.
        let raw = results.first { $0.strategyID == OptimizationStrategyRegistry.kvRaw.id }
        #expect(raw?.median.qualityScore == 1.0)
        if let q = turbo?.median.qualityScore { #expect(q < 1.0) }
    }

    @Test
    func jsonValidityHelper() {
        #expect(BenchmarkHarness.isValidJSON("{\"a\":1}"))
        #expect(!BenchmarkHarness.isValidJSON("not json"))
    }
}

@Suite
struct ExecutionProfileReflectionTests {
    @Test
    func reflectsCacheModeAsKVStrategy() {
        let raw = ExternalInferenceService.executionProfile(backend: .mlx, modelID: "m", cacheMode: .raw, usedPromptCache: false)
        #expect(raw.strategyID(for: .kvCache) == OptimizationStrategyRegistry.kvRaw.id)
        #expect(raw.strategyID(for: .promptCache) == OptimizationStrategyRegistry.promptOff.id)

        let turbo = ExternalInferenceService.executionProfile(backend: .mlx, modelID: "m", cacheMode: .turbo, usedPromptCache: true)
        #expect(turbo.strategyID(for: .kvCache) == OptimizationStrategyRegistry.kvTurbo.id)
        #expect(turbo.strategyID(for: .promptCache) == OptimizationStrategyRegistry.promptReuse.id)

        let tri = ExternalInferenceService.executionProfile(backend: .mlx, modelID: "m", cacheMode: .triattention, usedPromptCache: false)
        #expect(tri.strategyID(for: .kvCache) == OptimizationStrategyRegistry.kvTriAttention.id)
    }
}
