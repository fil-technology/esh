import Foundation
import Testing
@testable import EshCore

@Suite
struct CapabilitySchedulerTests {
    private func imageEvidence() -> CapabilityEvidenceIndex {
        CapabilityEvidenceIndex(evidence: [
            CapabilityPerformanceEvidence(capability: .imageGenerate, providerID: "image-generation", modelID: "z-image-turbo",
                config: ["width": .int(1024), "height": .int(1024), "steps": .int(8)], secondsPerUnit: 214.8, unit: "image", reliability: 1),
            CapabilityPerformanceEvidence(capability: .imageGenerate, providerID: "image-generation", modelID: "z-image-turbo",
                config: ["width": .int(512), "height": .int(512), "steps": .int(8)], secondsPerUnit: 51.0, unit: "image", reliability: 1),
        ])
    }

    @Test
    func interactiveImageGenPrefersWithinBudgetResolution() {
        let sched = CapabilityScheduler(index: imageEvidence(), interactiveBudgetSeconds: 60)
        let d = sched.decide(capability: .imageGenerate, currentModel: nil, candidateModelIDs: [],
                             requestedConfig: [:], latency: .interactive)
        #expect(d.optionOverrides["width"] == .int(512))
        #expect(d.optionOverrides["height"] == .int(512))
        #expect(d.evidenceBacked)
        #expect(d.rationale.contains { $0.contains("512x512") })
    }

    @Test
    func batchLeavesResolutionAlone() {
        let sched = CapabilityScheduler(index: imageEvidence(), interactiveBudgetSeconds: 60)
        let d = sched.decide(capability: .imageGenerate, currentModel: nil, candidateModelIDs: [],
                             requestedConfig: [:], latency: .batch)
        #expect(d.optionOverrides.isEmpty)
    }

    @Test
    func explicitResolutionIsRespected() {
        let sched = CapabilityScheduler(index: imageEvidence(), interactiveBudgetSeconds: 60)
        let d = sched.decide(capability: .imageGenerate, currentModel: nil, candidateModelIDs: [],
                             requestedConfig: ["width": .int(1024), "height": .int(1024)], latency: .interactive)
        #expect(d.optionOverrides.isEmpty)   // user asked for 1024² — don't override
    }

    @Test
    func picksFasterModelAmongCandidatesForInteractive() {
        let idx = CapabilityEvidenceIndex(evidence: [
            CapabilityPerformanceEvidence(capability: .imageGenerate, providerID: "p", modelID: "heavy",
                config: [:], secondsPerUnit: 200, unit: "image", reliability: 1),
            CapabilityPerformanceEvidence(capability: .imageGenerate, providerID: "p", modelID: "light",
                config: [:], secondsPerUnit: 25, unit: "image", reliability: 0.9),
        ])
        let d = CapabilityScheduler(index: idx).decide(capability: .imageGenerate, currentModel: nil,
            candidateModelIDs: ["heavy", "light"], requestedConfig: [:], latency: .interactive)
        #expect(d.modelID == "light")
        #expect(d.evidenceBacked)
    }

    @Test
    func executeCollectingFoldsSchedulerRationaleIntoPlan() async throws {
        // A provider that emits its own single-step plan; the scheduler's rationale must be folded in.
        let provider = ImageGenerationProvider(generate: { _, outPath, _, _, w, h, _, _, _ in
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: outPath))
            return (w ?? 1024, h ?? 1024)
        })
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("esh-sched-\(UUID().uuidString)")
        let ctx = ExecutionContext(root: PersistenceRoot(rootURL: dir), artifactStore: FileArtifactStore(rootURL: dir.appendingPathComponent("art")))
        defer { try? FileManager.default.removeItem(at: dir) }
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [provider]), context: ctx,
            scheduler: CapabilityScheduler(index: imageEvidence(), interactiveBudgetSeconds: 60),
            candidateModels: { _ in [] })
        let result = try await svc.executeCollecting(ExecutionRequest(
            capability: .imageGenerate, inputs: [.text("a fox")], output: .init(modality: .image),
            constraints: ExecutionConstraints(latency: .interactive)))
        let plan = try #require(result.plan)
        #expect(plan.evidenceBacked)
        #expect(plan.rationale.contains { $0.contains("512x512") })
        // The override actually reached the provider → produced a 512² artifact.
        #expect(result.outputs.first?.metadata["width"] == .int(512))
    }
}
