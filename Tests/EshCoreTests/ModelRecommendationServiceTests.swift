import Foundation
import Testing
@testable import EshCore

@Suite
struct ModelRecommendationServiceTests {
    private let service = ModelRecommendationService()

    private func host(gb: Double) -> HostMachineProfile {
        HostMachineProfile(chipDescription: "Apple M-test", totalMemoryGB: gb, availableMemoryGB: gb * 0.6, safeBudgetGB: gb * 0.6)
    }
    private func root() -> PersistenceRoot { PersistenceRoot(rootURL: tempDir()) }

    @Test
    func hardwareClassBuckets() {
        #expect(HardwareClass(totalMemoryGB: 8) == .gb8)
        #expect(HardwareClass(totalMemoryGB: 18) == .gb16)
        #expect(HardwareClass(totalMemoryGB: 32) == .gb32)
        #expect(HardwareClass(totalMemoryGB: 128) == .gb96)
    }

    @Test
    func codingProfileReturnsOnlyCodingModels() {
        let recs = service.recommend(profile: .coding, host: host(gb: 32), root: root(), limit: 5)
        #expect(!recs.isEmpty)
        #expect(recs.allSatisfy { $0.profile == .coding })
        // Every recommended model must be coding-capable in the catalog.
        let reg = RecommendedModelRegistry()
        #expect(recs.allSatisfy { rec in reg.resolve(alias: rec.modelID)?.capabilities.contains(.coding) == true })
    }

    @Test
    func fastPrefersSmallerThanBestQuality() {
        let fast = service.recommend(profile: .fast, host: host(gb: 32), root: root(), limit: 1).first
        let best = service.recommend(profile: .bestQuality, host: host(gb: 32), root: root(), limit: 1).first
        #expect(fast != nil && best != nil)
        #expect((fast?.peakMemoryGB ?? .greatestFiniteMagnitude) <= (best?.peakMemoryGB ?? 0))
    }

    @Test
    func fitAwareExcludesTooBigOnSmallMac() {
        // On an 8 GB Mac, no recommendation should be an unlikely/oversized model.
        let recs = service.recommend(profile: .bestQuality, host: host(gb: 8), root: root(), limit: 5)
        #expect(recs.allSatisfy { $0.fit != ModelFitClass.unlikely.rawValue && $0.fit != ModelFitClass.unsupported.rawValue })
        // Peak memory must be within reason for 8 GB.
        #expect(recs.allSatisfy { ($0.peakMemoryGB ?? 0) < 8 })
    }

    @Test
    func evidenceIsEstimatedWithoutLocalBenchmarks() {
        let recs = service.recommend(profile: .general, host: host(gb: 32), root: root(), limit: 3)
        #expect(recs.allSatisfy { $0.evidence == .estimated })  // no installs/benchmarks in temp root
    }

    @Test
    func datasetCoversAllProfilesAndIsVersioned() {
        let dataset = service.dataset(host: host(gb: 32), root: root())
        #expect(dataset.datasetVersion == ModelRecommendationService.datasetVersion)
        #expect(dataset.scoringVersion == ModelRecommendationService.scoringVersion)
        let profiles = Set(dataset.recommendations.map { $0.profile })
        #expect(profiles.contains(.coding))
        #expect(profiles.contains(.fast))
        #expect(profiles.contains(.bestQuality))
    }

    @Test
    func ranksAreAssignedInOrder() {
        let recs = service.recommend(profile: .general, host: host(gb: 32), root: root(), limit: 3)
        for (i, r) in recs.enumerated() { #expect(r.rank == i + 1) }
    }

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
