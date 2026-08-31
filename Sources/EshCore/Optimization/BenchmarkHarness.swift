import Foundation

/// A single generation performed by the harness, returning the real output + measured metrics.
public struct BenchmarkRunOutput: Sendable {
    public var outputText: String
    public var ttftMs: Double?
    public var decodeTokensPerSec: Double?
    public var prefillTokensPerSec: Double?
    public var endToEndMs: Double?
    public var tokensGenerated: Int?
    public var memoryBytes: Int64?
    public var kvCacheBytes: Int64?

    public init(
        outputText: String,
        ttftMs: Double? = nil,
        decodeTokensPerSec: Double? = nil,
        prefillTokensPerSec: Double? = nil,
        endToEndMs: Double? = nil,
        tokensGenerated: Int? = nil,
        memoryBytes: Int64? = nil,
        kvCacheBytes: Int64? = nil
    ) {
        self.outputText = outputText
        self.ttftMs = ttftMs
        self.decodeTokensPerSec = decodeTokensPerSec
        self.prefillTokensPerSec = prefillTokensPerSec
        self.endToEndMs = endToEndMs
        self.tokensGenerated = tokensGenerated
        self.memoryBytes = memoryBytes
        self.kvCacheBytes = kvCacheBytes
    }
}

/// Abstraction over "run one generation". The production adapter drives the SAME
/// ExternalInferenceService the CLI/server use (real path); tests use a deterministic mock.
public protocol BenchmarkInferenceRunner: Sendable {
    func generate(
        model: String,
        backend: BackendKind,
        cacheMode: CacheMode,
        prompt: String,
        maxTokens: Int,
        seed: Int?
    ) async throws -> BenchmarkRunOutput
}

/// A benchmark scenario: a workload shape at an approximate context size.
public struct BenchmarkScenario: Sendable {
    public var name: String
    public var workload: OptimizationWorkload
    public var approxContextTokens: Int
    public var prompt: String
    public var maxTokens: Int
    /// When true, the output is expected to be valid JSON (structured-output correctness check).
    public var expectsJSON: Bool

    public init(name: String, workload: OptimizationWorkload, approxContextTokens: Int, prompt: String, maxTokens: Int, expectsJSON: Bool = false) {
        self.name = name
        self.workload = workload
        self.approxContextTokens = approxContextTokens
        self.prompt = prompt
        self.maxTokens = maxTokens
        self.expectsJSON = expectsJSON
    }

    /// A small, representative v1 suite. Kept intentionally short; expand per model capacity.
    public static let v1Suite: [BenchmarkScenario] = [
        BenchmarkScenario(name: "chat-short", workload: .chat, approxContextTokens: 512,
                          prompt: "In two sentences, explain what a Mac's unified memory is.", maxTokens: 96),
        BenchmarkScenario(name: "coding-medium", workload: .coding, approxContextTokens: 3000,
                          prompt: "Write a Swift function that reverses the words in a string, then explain it briefly.", maxTokens: 160),
        BenchmarkScenario(name: "structured-json", workload: .structured, approxContextTokens: 800,
                          prompt: "Return ONLY a JSON object with keys name (string) and score (number) for a fictional model. No prose.", maxTokens: 64, expectsJSON: true),
        BenchmarkScenario(name: "reasoning-long", workload: .reasoning, approxContextTokens: 8000,
                          prompt: "Think step by step: if a train travels 60 km in 45 minutes, what is its speed in km/h? Show the steps.", maxTokens: 200)
    ]
}

public struct BenchmarkOptions: Sendable {
    public var warmupRuns: Int
    public var measuredRuns: Int
    public var seed: Int?
    public init(warmupRuns: Int = 1, measuredRuns: Int = 3, seed: Int? = 42) {
        self.warmupRuns = warmupRuns
        self.measuredRuns = measuredRuns
        self.seed = seed
    }
    public static let quick = BenchmarkOptions(warmupRuns: 0, measuredRuns: 1)
    public static let full = BenchmarkOptions(warmupRuns: 1, measuredRuns: 5)
}

/// Runs strategies × scenarios through the real inference path, computes median metrics + a quality
/// proxy, and persists reproducible results. Never fabricates numbers: every metric comes from the
/// runner, and missing measurements stay nil.
public struct BenchmarkHarness: Sendable {
    private let registry: OptimizationStrategyRegistry
    private let eshVersion: String?
    private let gitSHA: String?

    public init(
        registry: OptimizationStrategyRegistry = OptimizationStrategyRegistry(),
        eshVersion: String? = nil,
        gitSHA: String? = nil
    ) {
        self.registry = registry
        self.eshVersion = eshVersion
        self.gitSHA = gitSHA
    }

    /// Benchmark the eligible KV-cache strategies for a model across the scenario suite.
    public func benchmarkKVCache(
        model: String,
        backend: BackendKind,
        host: HostMachineProfile?,
        runtimeVersion: String?,
        scenarios: [BenchmarkScenario] = BenchmarkScenario.v1Suite,
        options: BenchmarkOptions = BenchmarkOptions(),
        runner: BenchmarkInferenceRunner,
        recordedAtISO8601: String,
        progress: (@Sendable (String) -> Void)? = nil
    ) async -> [OptimizationBenchmarkResult] {
        let context = OptimizationContext(backend: backend, modelID: model, runtimeVersion: runtimeVersion, host: host)
        let strategies = registry.compatibleStrategies(category: .kvCache, context: context)
        let key = OptimizationProfileKey(
            hardwareFingerprint: OptimizationProfileKey.hardwareFingerprint(from: host),
            modelID: model, backend: backend.rawValue, runtimeVersion: runtimeVersion
        )

        var results: [OptimizationBenchmarkResult] = []
        // Baseline first, so quality-changing strategies can be compared against it per scenario.
        let ordered = strategies.sorted { ($0.isBaseline ? 0 : 1) < ($1.isBaseline ? 0 : 1) }

        for scenario in scenarios {
            var baselineOutput: String?
            for strategy in ordered {
                let cacheMode = cacheMode(for: strategy)
                progress?("Benchmarking \(strategy.id) · \(scenario.name)")
                var samples: [BenchmarkMetrics] = []
                var lastOutput = ""
                var errorCount = 0

                for _ in 0..<max(0, options.warmupRuns) {
                    _ = try? await runner.generate(model: model, backend: backend, cacheMode: cacheMode, prompt: scenario.prompt, maxTokens: scenario.maxTokens, seed: options.seed)
                }
                for _ in 0..<max(1, options.measuredRuns) {
                    do {
                        let out = try await runner.generate(model: model, backend: backend, cacheMode: cacheMode, prompt: scenario.prompt, maxTokens: scenario.maxTokens, seed: options.seed)
                        lastOutput = out.outputText
                        samples.append(metrics(from: out, scenario: scenario, strategy: strategy, baseline: baselineOutput))
                    } catch {
                        errorCount += 1
                    }
                }
                if strategy.isBaseline { baselineOutput = lastOutput }

                let median = medianMetrics(samples, errorCount: errorCount)
                results.append(OptimizationBenchmarkResult(
                    key: key,
                    category: .kvCache,
                    strategyID: strategy.id,
                    workload: scenario.workload,
                    contextBucket: ContextBucket(tokens: scenario.approxContextTokens),
                    median: median,
                    samples: samples,
                    recordedAtISO8601: recordedAtISO8601,
                    eshVersion: eshVersion,
                    gitSHA: gitSHA
                ))
            }
        }
        return results
    }

    // MARK: - Metric assembly

    private func metrics(from out: BenchmarkRunOutput, scenario: BenchmarkScenario, strategy: OptimizationStrategy, baseline: String?) -> BenchmarkMetrics {
        var m = BenchmarkMetrics(
            ttftMs: out.ttftMs,
            prefillTokensPerSec: out.prefillTokensPerSec,
            decodeTokensPerSec: out.decodeTokensPerSec,
            endToEndMs: out.endToEndMs,
            tokensGenerated: out.tokensGenerated,
            memoryBeforeBytes: nil,
            peakMemoryBytes: out.memoryBytes,
            kvCacheBytes: out.kvCacheBytes,
            errorCount: 0
        )
        if scenario.expectsJSON {
            m.jsonValidityRate = Self.isValidJSON(out.outputText) ? 1.0 : 0.0
        }
        if strategy.distributionEquivalent {
            m.distributionEquivalentToBaseline = true
            m.qualityScore = 1.0
        } else if let baseline {
            // Quality proxy for a quality-changing strategy: token-overlap similarity vs baseline
            // output under the same prompt+seed. A crude but honest semantic-regression signal.
            let score = Self.tokenOverlap(out.outputText, baseline)
            m.qualityScore = score
            m.distributionEquivalentToBaseline = score >= 0.999
        }
        return m
    }

    private func medianMetrics(_ samples: [BenchmarkMetrics], errorCount: Int) -> BenchmarkMetrics {
        func med(_ f: (BenchmarkMetrics) -> Double?) -> Double? { Self.median(samples.compactMap(f)) }
        func medI(_ f: (BenchmarkMetrics) -> Int64?) -> Int64? { Self.median(samples.compactMap { f($0).map(Double.init) }).map { Int64($0) } }
        return BenchmarkMetrics(
            ttftMs: med { $0.ttftMs },
            prefillTokensPerSec: med { $0.prefillTokensPerSec },
            decodeTokensPerSec: med { $0.decodeTokensPerSec },
            endToEndMs: med { $0.endToEndMs },
            tokensGenerated: samples.compactMap { $0.tokensGenerated }.max(),
            peakMemoryBytes: medI { $0.peakMemoryBytes },
            kvCacheBytes: medI { $0.kvCacheBytes },
            jsonValidityRate: med { $0.jsonValidityRate },
            distributionEquivalentToBaseline: samples.compactMap { $0.distributionEquivalentToBaseline }.allSatisfy { $0 } ? (samples.contains { $0.distributionEquivalentToBaseline != nil } ? true : nil) : false,
            qualityScore: med { $0.qualityScore },
            errorCount: errorCount
        )
    }

    private func cacheMode(for strategy: OptimizationStrategy) -> CacheMode {
        switch strategy.id {
        case OptimizationStrategyRegistry.kvTurbo.id: return .turbo
        case OptimizationStrategyRegistry.kvTriAttention.id: return .triattention
        default: return .raw
        }
    }

    // MARK: - Helpers

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    static func isValidJSON(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    static func tokenOverlap(_ a: String, _ b: String) -> Double {
        let ta = Set(a.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
        let tb = Set(b.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
        guard !ta.isEmpty || !tb.isEmpty else { return 1.0 }
        let inter = ta.intersection(tb).count
        let union = ta.union(tb).count
        return union == 0 ? 1.0 : Double(inter) / Double(union)
    }
}
