import Foundation

/// Persists the versioned local benchmark dataset (small JSON on the state root).
public struct ModelBenchmarkLabStore: Sendable {
    private let fileURL: URL

    public init(root: PersistenceRoot) {
        self.fileURL = root.benchmarksURL.appendingPathComponent("model-benchmark-dataset.json")
    }

    public func load() -> ModelBenchmarkDataset {
        guard let data = try? Data(contentsOf: fileURL),
              let dataset = try? JSONCoding.decoder.decode(ModelBenchmarkDataset.self, from: data) else {
            return ModelBenchmarkDataset()
        }
        return dataset
    }

    public func save(_ dataset: ModelBenchmarkDataset) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONCoding.encoder.encode(dataset)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Merge new evidence, replacing any prior evidence for the same model.
    public func upsert(_ newEvidence: [ModelBenchmarkEvidence]) throws -> ModelBenchmarkDataset {
        var dataset = load()
        let updatedIDs = Set(newEvidence.map(\.modelID))
        dataset.evidence.removeAll { updatedIDs.contains($0.modelID) }
        dataset.evidence.append(contentsOf: newEvidence)
        dataset.evidence.sort { $0.modelID < $1.modelID }
        try save(dataset)
        return dataset
    }
}

/// A deterministic quality probe: a fixed prompt with a checkable answer.
public struct BenchmarkProbe: Sendable {
    public let id: String
    public let category: String
    public let prompt: String
    public let maxTokens: Int
    public let check: @Sendable (String) -> Bool

    public init(id: String, category: String, prompt: String, maxTokens: Int, check: @escaping @Sendable (String) -> Bool) {
        self.id = id
        self.category = category
        self.prompt = prompt
        self.maxTokens = maxTokens
        self.check = check
    }
}

/// The Model Benchmark Lab: runs deterministic probes against real models (through an injected
/// inference closure that uses esh's own inference path — not a duplicate runtime), measures
/// performance from the real runtime metrics, and produces versioned evidence. Quality checks are
/// deterministic; nothing is fabricated.
public struct ModelBenchmarkLabService: Sendable {
    public static let suiteVersion = 1

    /// Runs one probe against a model and returns the reply text plus the runtime metrics.
    public typealias ProbeRunner = @Sendable (_ install: ModelInstall, _ prompt: String, _ maxTokens: Int) async throws -> (text: String, metrics: Metrics)

    private let runProbe: ProbeRunner
    private let hardware: String
    private let eshVersion: String?

    public init(hardware: String, eshVersion: String?, runProbe: @escaping ProbeRunner) {
        self.hardware = hardware
        self.eshVersion = eshVersion
        self.runProbe = runProbe
    }

    public static let defaultProbes: [BenchmarkProbe] = [
        BenchmarkProbe(id: "math", category: "reasoning", maxTokensDefault: 24,
                       prompt: "What is 17 multiplied by 23? Reply with only the number.") { $0.contains("391") },
        BenchmarkProbe(id: "instruction", category: "instruction", maxTokensDefault: 12,
                       prompt: "Reply with exactly the single word: BANANA (uppercase, nothing else).") { $0.uppercased().contains("BANANA") },
        BenchmarkProbe(id: "structured", category: "structured", maxTokensDefault: 48,
                       prompt: "Output a JSON object with keys \"a\" and \"b\" set to 1 and 2. Only JSON.") { BenchmarkChecks.looksLikeJSONObject($0) },
        BenchmarkProbe(id: "coding", category: "coding", maxTokensDefault: 48,
                       prompt: "Write a Python one-liner that returns the sum of a list `xs`. Reply with only code.") { $0.replacingOccurrences(of: " ", with: "").contains("sum(xs") },
        BenchmarkProbe(id: "general", category: "general", maxTokensDefault: 12,
                       prompt: "What is the capital of Japan? One word.") { $0.lowercased().contains("tokyo") }
    ]

    public func benchmark(install: ModelInstall, probes: [BenchmarkProbe] = defaultProbes) async -> ModelBenchmarkEvidence {
        var ttfts: [Double] = []
        var tpss: [Double] = []
        var mems: [Double] = []
        var results: [BenchmarkProbeResult] = []
        var stable = true

        for probe in probes {
            do {
                let (text, metrics) = try await runProbe(install, probe.prompt, probe.maxTokens)
                if let t = metrics.ttftMilliseconds { ttfts.append(t) }
                if let tps = metrics.tokensPerSecond { tpss.append(tps) }
                if let mem = metrics.memoryBytes { mems.append(Double(mem) / 1_000_000) }
                results.append(BenchmarkProbeResult(
                    id: probe.id, category: probe.category, passed: probe.check(text),
                    reply: String(text.prefix(80))))
            } catch {
                stable = false
                results.append(BenchmarkProbeResult(
                    id: probe.id, category: probe.category, passed: false,
                    error: String(error.localizedDescription.prefix(160))))
            }
        }

        let provenance = BenchmarkProvenance(
            dateISO8601: ISO8601DateFormatter().string(from: Date()),
            eshVersion: eshVersion,
            runtimeVersion: install.runtimeVersion,
            hardware: hardware,
            suiteVersion: Self.suiteVersion,
            quantization: install.spec.variant ?? install.backendFormat,
            contextTokens: nil
        )
        let performance = BenchmarkPerformance(
            ttftMillisecondsMedian: BenchmarkChecks.median(ttfts),
            decodeTokensPerSecondMedian: BenchmarkChecks.median(tpss),
            peakMemoryMB: mems.max(),
            modelDiskBytes: install.sizeBytes
        )
        let quality = BenchmarkQuality(
            passed: results.filter(\.passed).count, total: results.count, probes: results)
        return ModelBenchmarkEvidence(
            modelID: install.id, backend: install.spec.backend,
            provenance: provenance, performance: performance, quality: quality, stable: stable)
    }
}

public enum BenchmarkChecks {
    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        let m = sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        return (m * 10).rounded() / 10
    }

    public static func looksLikeJSONObject(_ text: String) -> Bool {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let start = t.firstIndex(of: "{"), let end = t.lastIndex(of: "}"), start < end else { return false }
        let candidate = String(t[start...end])
        guard let data = candidate.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }
}

private extension BenchmarkProbe {
    init(id: String, category: String, maxTokensDefault: Int, prompt: String, check: @escaping @Sendable (String) -> Bool) {
        self.init(id: id, category: category, prompt: prompt, maxTokens: maxTokensDefault, check: check)
    }
}
