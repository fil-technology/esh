import Foundation
import Testing
@testable import EshCore

@Suite
struct ImageUpscaleBenchmarkTests {
    private func tempRoot() -> PersistenceRoot {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("esh-uptest-\(UUID().uuidString)")
        return PersistenceRoot(stateRootURL: dir, assetsRootURL: dir)
    }

    @Test func storeRoundTripsAndDedupesByConfig() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root.rootURL) }
        let store = ImageUpscaleBenchmarkStore(root: root)
        func ev(_ warm: Double) -> CapabilityPerformanceEvidence {
            CapabilityPerformanceEvidence(capability: .imageUpscale, providerID: "image-upscale", modelID: "m",
                config: ["width": .int(512), "height": .int(512), "scale": .int(2)],
                warmMs: warm, secondsPerUnit: warm / 1000, unit: "image", reliability: 1)
        }
        try store.upsert(ev(9000))
        try store.upsert(ev(7000))   // same config key → replaces
        let ds = store.load()
        #expect(ds.evidence.count == 1)
        #expect(ds.evidence.first?.warmMs == 7000)
    }

    @Test func synthesizesValidPNGAtRequestedSize() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("esh-png-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("g.png").path
        try ImageUpscaleBenchmarkRunner.writeGradientPNG(width: 128, height: 96, to: path)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(data.count > 100)
        #expect(Array(data.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])   // PNG signature
    }

    @Test func evidenceFeedsIntoTheSharedIndex() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root.rootURL) }
        try ImageUpscaleBenchmarkStore(root: root).upsert(CapabilityPerformanceEvidence(
            capability: .imageUpscale, providerID: "image-upscale", modelID: "m",
            config: ["width": .int(512), "scale": .int(2)], warmMs: 8000, secondsPerUnit: 8, unit: "image", reliability: 1))
        let index = CapabilityEvidenceIndex(root: root)
        #expect(index.all(capability: .imageUpscale).count == 1)
        #expect(index.best(capability: .imageUpscale)?.secondsPerUnit == 8)
    }
}

@Suite
struct ImageUpscaleFitTests {
    private let host = HostMachineProfile(chipDescription: "Apple M1 Pro", totalMemoryGB: 32, availableMemoryGB: 16)

    @Test func smallImageIsComfortableAndLatencyUnknownWithoutEvidence() {
        let fit = ImageUpscaleFitService().assess(inputWidth: 512, inputHeight: 512, scale: 2,
            host: host, evidence: CapabilityEvidenceIndex(evidence: []))
        #expect(fit.memoryFit == .comfortable)
        #expect(fit.outputWidth == 1024 && fit.outputHeight == 1024)
        #expect(fit.expectedSeconds == nil)          // no measurement → honestly unknown
        #expect(!fit.evidenceBacked)
        #expect(fit.note.contains("does not imply interactive speed"))
    }

    @Test func expectedLatencyComesFromMeasuredEvidence() {
        let evidence = CapabilityEvidenceIndex(evidence: [
            CapabilityPerformanceEvidence(capability: .imageUpscale, providerID: "image-upscale", modelID: "m",
                config: ["width": .int(512), "scale": .int(2)], secondsPerUnit: 9.5, unit: "image", reliability: 1)])
        let fit = ImageUpscaleFitService().assess(inputWidth: 512, inputHeight: 512, scale: 2, host: host, evidence: evidence)
        #expect(fit.evidenceBacked)
        #expect(fit.expectedSeconds == 9.5)
    }

    @Test func largeImageIsTiledLikely() {
        let fit = ImageUpscaleFitService().assess(inputWidth: 2048, inputHeight: 2048, scale: 4,
            host: host, evidence: CapabilityEvidenceIndex(evidence: []))
        #expect(fit.tiledLikely)   // above the tile threshold → peak memory bounded by tiling
    }
}
