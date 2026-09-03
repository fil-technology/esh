import Foundation
import Testing
@testable import EshCore

@Suite
struct CapabilityPerformanceEvidenceTests {
    private func prov() -> BenchmarkProvenance {
        BenchmarkProvenance(dateISO8601: "2026-09-03T00:00:00Z", eshVersion: "2.1", runtimeVersion: "mflux 0.19.1",
                            hardware: "M1 Pro / 32 GB", suiteVersion: 1, quantization: "4-bit", contextTokens: nil)
    }

    @Test
    func bestPrefersFasterAtMatchingConfig() {
        let ev = [
            CapabilityPerformanceEvidence(capability: .imageGenerate, providerID: "image-generation", modelID: "z-image-turbo",
                config: ["width": .int(1024), "height": .int(1024), "steps": .int(8)], secondsPerUnit: 214.8, unit: "image", reliability: 1),
            CapabilityPerformanceEvidence(capability: .imageGenerate, providerID: "image-generation", modelID: "z-image-turbo",
                config: ["width": .int(512), "height": .int(512), "steps": .int(8)], secondsPerUnit: 51.0, unit: "image", reliability: 1),
        ]
        let idx = CapabilityEvidenceIndex(evidence: ev)
        // At 512² the 512 sample (51s) is chosen, not the 1024 one.
        let at512 = idx.best(capability: .imageGenerate, config: ["width": .int(512), "height": .int(512)], prefer: .fastest)
        #expect(at512?.secondsPerUnit == 51.0)
        // With no config constraint, fastest overall wins.
        #expect(idx.best(capability: .imageGenerate, prefer: .fastest)?.secondsPerUnit == 51.0)
        #expect(idx.all(capability: .imageGenerate).count == 2)
    }

    @Test
    func experimentalAndPressuredSamplesAreExcludedWhenCleanerExist() {
        let ev = [
            CapabilityPerformanceEvidence(capability: .imageUpscale, providerID: "image-upscale", modelID: "seedvr2",
                secondsPerUnit: 5, unit: "image", experimental: true),
            CapabilityPerformanceEvidence(capability: .imageUpscale, providerID: "image-upscale", modelID: "realesrgan",
                secondsPerUnit: 12, unit: "image", experimental: false),
        ]
        let idx = CapabilityEvidenceIndex(evidence: ev)
        // The fast one is experimental → excluded; the real (12s) one is chosen even though slower.
        #expect(idx.best(capability: .imageUpscale, prefer: .fastest)?.modelID == "realesrgan")

        let ev2 = [
            CapabilityPerformanceEvidence(capability: .imageGenerate, providerID: "p", modelID: "pressured",
                secondsPerUnit: 100, unit: "image", measuredUnderMemoryPressure: true),
            CapabilityPerformanceEvidence(capability: .imageGenerate, providerID: "p", modelID: "clean",
                secondsPerUnit: 200, unit: "image", measuredUnderMemoryPressure: false),
        ]
        // The clean (200s) sample is preferred over the faster-but-pressured (100s) one.
        #expect(CapabilityEvidenceIndex(evidence: ev2).best(capability: .imageGenerate, prefer: .fastest)?.modelID == "clean")
    }

    @Test
    func adaptsImageGenerationBenchmarkAndReadsFromStore() throws {
        let root = PersistenceRoot(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("esh-ev-\(UUID().uuidString)"))
        let b = ImageGenerationBenchmark(modelID: "z-image-turbo", provenance: prov(), requestedWidth: 512, requestedHeight: 512,
            steps: 8, coldLoadAndGenerateMs: 60000, warmGenerateMsMedian: 51000, secondsPerImageMedian: 51.0,
            peakMemoryMB: 4416, residentMemoryMB: nil, outputValidCount: 3, totalRuns: 3, sampleLatenciesMs: [51000],
            stable: true, measuredUnderMemoryPressure: false, note: "compute-bound")
        try ImageGenerationBenchmarkStore(root: root).upsert(b)
        let idx = CapabilityEvidenceIndex(root: root)
        let e = try #require(idx.best(capability: .imageGenerate, config: ["width": .int(512)], prefer: .fastest))
        #expect(e.secondsPerUnit == 51.0)
        #expect(e.unit == "image")
        #expect(e.reliability == 1.0)               // 3/3 valid
        #expect(e.peakMemoryMB == 4416)
    }
}
