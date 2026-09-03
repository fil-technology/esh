import Foundation
import Testing
@testable import EshCore

@Suite
struct ImageGenerationBenchmarkTests {
    private func provenance() -> BenchmarkProvenance {
        BenchmarkProvenance(dateISO8601: "2026-09-03T00:00:00Z", eshVersion: "2.1.0",
                            runtimeVersion: "mflux 0.19.1", hardware: "Apple M-test / 64 GB",
                            suiteVersion: ImageGenerationBenchmarkRunner.suiteVersion,
                            quantization: "z-image-turbo", contextTokens: nil)
    }

    @Test
    func runComputesMediansValidityAndStability() async {
        // Mock generator: valid images at requested size, cold slower than warm, tight warm spread → stable.
        // seed 0 = cold; seeds 1..3 = warm. Indexing by seed keeps the closure Sendable (no captured var).
        let latencies = [12000.0, 900.0, 1000.0, 1100.0]
        let runner = ImageGenerationBenchmarkRunner(generate: { _, w, h, _, seed in
            ImageGenProbeOutput(outputWidth: w, outputHeight: h, elapsedMs: latencies[min(seed, latencies.count - 1)], peakMemoryMB: 9000)
        })
        let b = await runner.run(modelID: "z-image-turbo", provenance: provenance(), width: 1024, height: 1024, steps: 8, measuredRuns: 3)
        #expect(b.coldLoadAndGenerateMs == 12000)
        #expect(b.warmGenerateMsMedian == 1000)
        #expect(b.secondsPerImageMedian == 1.0)
        #expect(b.outputValidCount == 4 && b.totalRuns == 4)
        #expect(b.peakMemoryMB == 9000)
        #expect(b.stable)
    }

    @Test
    func wrongDimensionsMarkInvalidAndUnstable() async {
        let runner = ImageGenerationBenchmarkRunner(generate: { _, _, _, _, _ in
            ImageGenProbeOutput(outputWidth: 64, outputHeight: 64, elapsedMs: 1000)  // wrong size
        })
        let b = await runner.run(modelID: "m", provenance: provenance(), width: 1024, height: 1024, measuredRuns: 2)
        #expect(b.outputValidCount == 0)
        #expect(!b.stable)
    }

    @Test
    func storeRoundTripsAndUpserts() throws {
        let root = PersistenceRoot(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("esh-imgbench-\(UUID().uuidString)"))
        let store = ImageGenerationBenchmarkStore(root: root)
        let mk = { (ms: Double) in ImageGenerationBenchmark(
            modelID: "z-image-turbo", provenance: self.provenance(), requestedWidth: 1024, requestedHeight: 1024, steps: 8,
            coldLoadAndGenerateMs: 12000, warmGenerateMsMedian: ms, secondsPerImageMedian: ms / 1000, peakMemoryMB: 9000,
            residentMemoryMB: nil, outputValidCount: 4, totalRuns: 4, sampleLatenciesMs: [ms], stable: true) }
        _ = try store.upsert(mk(1000))
        let ds = try store.upsert(mk(800))   // same key → replaces
        #expect(ds.benchmarks.count == 1)
        #expect(store.load().benchmarks.first?.warmGenerateMsMedian == 800)
    }
}
