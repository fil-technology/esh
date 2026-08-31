import Foundation
import Testing
@testable import EshCore

@Suite
struct ModelBenchmarkLabTests {

    private func install(_ id: String, backend: BackendKind = .mlx) -> ModelInstall {
        ModelInstall(
            id: id,
            spec: ModelSpec(id: id, displayName: id, backend: backend,
                            source: ModelSource(kind: .huggingFace, reference: "org/\(id)")),
            installPath: "/tmp/\(id)", sizeBytes: 1_000_000, backendFormat: backend.rawValue, runtimeVersion: "rt-1")
    }

    @Test
    func medianAndJSONChecksAreCorrect() {
        #expect(BenchmarkChecks.median([]) == nil)
        #expect(BenchmarkChecks.median([10, 20, 30]) == 20)
        #expect(BenchmarkChecks.median([10, 20]) == 15)
        #expect(BenchmarkChecks.looksLikeJSONObject(#"{"a":1,"b":2}"#))
        #expect(BenchmarkChecks.looksLikeJSONObject("```json\n{\"a\":1}\n```"))
        #expect(BenchmarkChecks.looksLikeJSONObject("not json") == false)
    }

    @Test
    func benchmarkAggregatesRealMetricsAndDeterministicQuality() async {
        // Mock probe runner: returns a correct answer for every default probe + fixed metrics, so we
        // exercise scoring/aggregation without a live model.
        let answers: [String: String] = [
            "What is 17 multiplied by 23? Reply with only the number.": "391",
            "Reply with exactly the single word: BANANA (uppercase, nothing else).": "BANANA",
            "Output a JSON object with keys \"a\" and \"b\" set to 1 and 2. Only JSON.": #"{"a":1,"b":2}"#,
            "Write a Python one-liner that returns the sum of a list `xs`. Reply with only code.": "sum(xs)",
            "What is the capital of Japan? One word.": "Tokyo"
        ]
        let lab = ModelBenchmarkLabService(hardware: "Test / 16 GB", eshVersion: "9.9.9") { _, prompt, _ in
            (answers[prompt] ?? "?", Metrics(ttftMilliseconds: 50, tokensPerSecond: 120, memoryBytes: 500_000_000))
        }
        let evidence = await lab.benchmark(install: install("m"))
        #expect(evidence.quality.passed == 5)
        #expect(evidence.quality.total == 5)
        #expect(evidence.performance.ttftMillisecondsMedian == 50)
        #expect(evidence.performance.decodeTokensPerSecondMedian == 120)
        #expect(evidence.performance.peakMemoryMB == 500)
        #expect(evidence.stable == true)
        #expect(evidence.provenance.eshVersion == "9.9.9")
        #expect(evidence.provenance.suiteVersion == ModelBenchmarkLabService.suiteVersion)
        #expect(evidence.quality.categoryPassRate["reasoning"] == 1.0)
    }

    @Test
    func failingProbesAndErrorsAreRecordedHonestly() async {
        let lab = ModelBenchmarkLabService(hardware: "Test", eshVersion: nil) { _, prompt, _ in
            if prompt.contains("17 multiplied") { throw StoreError.invalidManifest("boom") }
            return ("wrong", Metrics(ttftMilliseconds: 10, tokensPerSecond: 5))
        }
        let evidence = await lab.benchmark(install: install("m"))
        #expect(evidence.quality.passed == 0)          // all wrong
        #expect(evidence.stable == false)              // one probe errored
        #expect(evidence.quality.probes.contains { $0.error != nil })
    }

    @Test
    func storeRoundTripsAndUpsertsByModel() throws {
        let root = PersistenceRoot(rootURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("esh-bench-\(UUID().uuidString)", isDirectory: true))
        let store = ModelBenchmarkLabStore(root: root)
        #expect(store.load().evidence.isEmpty)

        func ev(_ id: String, passed: Int) -> ModelBenchmarkEvidence {
            ModelBenchmarkEvidence(
                modelID: id, backend: .mlx,
                provenance: BenchmarkProvenance(dateISO8601: "t", eshVersion: nil, runtimeVersion: nil,
                                                hardware: "h", suiteVersion: 1, quantization: nil, contextTokens: nil),
                performance: BenchmarkPerformance(),
                quality: BenchmarkQuality(passed: passed, total: 5, probes: []), stable: true)
        }
        _ = try store.upsert([ev("a", passed: 1), ev("b", passed: 2)])
        var dataset = store.load()
        #expect(dataset.evidence.count == 2)
        // Upsert replaces existing evidence for the same model, not duplicates it.
        _ = try store.upsert([ev("a", passed: 5)])
        dataset = store.load()
        #expect(dataset.evidence.count == 2)
        #expect(dataset.evidence(for: "a")?.quality.passed == 5)
    }
}
