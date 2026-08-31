import Foundation
import Testing
@testable import EshCore

@Suite
struct SchedulerServiceTests {
    private let scheduler = SchedulerService()

    private func host(gb: Double) -> HostMachineProfile {
        HostMachineProfile(chipDescription: "Apple M-test", totalMemoryGB: gb, availableMemoryGB: gb * 0.6, safeBudgetGB: gb * 0.6)
    }

    /// Build an install whose NAME drives heuristic capabilities and whose byte size drives the
    /// estimated parameter count (~ gib*8/4.5 bits).
    private func install(id: String, name: String, backend: BackendKind = .mlx, gib: Double) -> ModelInstall {
        let spec = ModelSpec(id: id, displayName: name, backend: backend,
                             source: ModelSource(kind: .localPath, reference: "local/\(name)"))
        return ModelInstall(id: id, spec: spec, installPath: "/tmp/\(id)",
                            sizeBytes: Int64(gib * 1_073_741_824), backendFormat: backend.rawValue)
    }

    private func decide(_ request: CapabilityRequest, _ installs: [ModelInstall], gb: Double, apple: Bool = false) -> SchedulerDecision {
        scheduler.decide(request: request, installs: installs, host: host(gb: gb),
                         root: PersistenceRoot(rootURL: tempDir()), appleAvailable: apple)
    }

    @Test
    func selectsCapableFittingModelForCoding() {
        let coder = install(id: "coder7b", name: "Qwen2.5-Coder-7B-Instruct", gib: 4.3)  // ~7.6B
        let chat = install(id: "chat3b", name: "Llama-3.2-3B-Instruct", gib: 1.8)         // chat only
        let d = decide(CapabilityRequest(goal: .coding, quality: .balanced), [coder, chat], gb: 32)
        #expect(d.selectedModelID == "coder7b")     // only the coder satisfies .coding
        #expect(d.backend == .mlx)
        #expect(d.executionProfile != nil)
        #expect(!d.rationale.isEmpty)
    }

    @Test
    func excludesModelsMissingRequiredCapability() {
        let chat = install(id: "chat3b", name: "Llama-3.2-3B-Instruct", gib: 1.8)
        let d = decide(CapabilityRequest(goal: .coding, quality: .balanced), [chat], gb: 32)
        #expect(d.selectedModelID == nil)           // no coder installed
    }

    @Test
    func qualityHighPrefersLargerFastPrefersSmaller() {
        let small = install(id: "coderSmall", name: "Qwen2.5-Coder-3B", gib: 1.8)   // ~3B
        let big = install(id: "coderBig", name: "Qwen2.5-Coder-14B", gib: 8.0)      // ~14B
        let high = decide(CapabilityRequest(goal: .coding, quality: .high), [small, big], gb: 64)
        let fast = decide(CapabilityRequest(goal: .coding, quality: .fast), [small, big], gb: 64)
        #expect(high.selectedModelID == "coderBig")
        #expect(fast.selectedModelID == "coderSmall")
    }

    @Test
    func tightFitSwitchesToMemoryMode() {
        // A ~32B coder (~20GB peak) on a 24GB Mac is tight -> memory mode.
        let big = install(id: "coder32b", name: "Qwen2.5-Coder-32B", gib: 18.0)     // ~32B
        let d = decide(CapabilityRequest(goal: .coding, quality: .high), [big], gb: 24)
        #expect(d.selectedModelID == "coder32b")
        #expect(d.performanceMode == .memory)
        #expect(d.fitClass == "tight" || d.fitClass == "unlikely")
    }

    @Test
    func suggestsAppleWhenNothingFitsAndRequestIsModest() {
        let d = decide(CapabilityRequest(goal: .general, quality: .balanced), [], gb: 32, apple: true)
        #expect(d.selectedModelID == nil)
        #expect(d.appleIntelligenceSuggested)
        // Honest: a suggestion, not a silent substitution.
        #expect(d.warnings.contains { $0.contains("will not use Apple Intelligence in place") })
    }

    @Test
    func doesNotSuggestAppleWhenToolsRequired() {
        let d = decide(CapabilityRequest(goal: .general, quality: .balanced, toolCallingRequired: true), [], gb: 32, apple: true)
        #expect(!d.appleIntelligenceSuggested)      // Apple isn't offered for tool-calling here
        #expect(d.selectedModelID == nil)
    }

    @Test
    func prefersWarmModelOnCloseCalls() {
        // Two similar coding models; the warm one should win a close call (M7 resource awareness).
        let cold = install(id: "coderCold", name: "Qwen2.5-Coder-7B-A", gib: 4.3)
        let warm = install(id: "coderWarm", name: "Qwen2.5-Coder-7B-B", gib: 4.2)
        let d = scheduler.decide(request: CapabilityRequest(goal: .coding, quality: .balanced),
                                 installs: [cold, warm], host: host(gb: 32),
                                 root: PersistenceRoot(rootURL: tempDir()), appleAvailable: false,
                                 warmModelIDs: ["coderWarm"])
        #expect(d.selectedModelID == "coderWarm")
        #expect(d.rationale.contains { $0.contains("already warm") })
    }

    @Test
    func muchBetterColdModelStillBeatsTinyWarmOne() {
        // A large cold coding model beats a tiny warm one for best-quality (warm bonus is bounded).
        let tinyWarm = install(id: "tiny", name: "Qwen2.5-Coder-1.5B", gib: 1.0)
        let bigCold = install(id: "big", name: "Qwen2.5-Coder-32B", gib: 18.0)
        let d = scheduler.decide(request: CapabilityRequest(goal: .coding, quality: .high),
                                 installs: [tinyWarm, bigCold], host: host(gb: 64),
                                 root: PersistenceRoot(rootURL: tempDir()), appleAvailable: false,
                                 warmModelIDs: ["tiny"])
        #expect(d.selectedModelID == "big")
    }

    @Test
    func recordsRationaleAndCandidateCount() {
        let coder = install(id: "coder7b", name: "Qwen2.5-Coder-7B", gib: 4.3)
        let d = decide(CapabilityRequest(goal: .coding, quality: .balanced), [coder], gb: 32)
        #expect(d.candidatesConsidered == 1)
        #expect(d.rationale.count >= 2)
    }

    // MARK: - Measured benchmark evidence (Scheduler Revalidation)

    private func evidence(_ id: String, stable: Bool, passed: Int, tps: Double?) -> ModelBenchmarkEvidence {
        ModelBenchmarkEvidence(
            modelID: id, backend: .mlx,
            provenance: BenchmarkProvenance(dateISO8601: "t", eshVersion: nil, runtimeVersion: nil,
                                            hardware: "h", suiteVersion: 1, quantization: nil, contextTokens: nil),
            performance: BenchmarkPerformance(decodeTokensPerSecondMedian: tps),
            quality: BenchmarkQuality(passed: passed, total: 5, probes: [
                BenchmarkProbeResult(id: "coding", category: "coding", passed: passed >= 3)
            ]),
            stable: stable)
    }

    @Test
    func measuredBrokenModelIsNotPreferredOverAWorkingOne() throws {
        // A large coder the curated catalog would rank first for a high-quality request, but which the
        // Benchmark Lab measured as FAILING to run — and a smaller working coder measured as good.
        let root = PersistenceRoot(rootURL: tempDir())
        let bigBroken = install(id: "coderBig", name: "Qwen2.5-Coder-14B", gib: 8.0)
        let smallGood = install(id: "coderSmall", name: "Qwen2.5-Coder-3B", gib: 1.8)
        _ = try ModelBenchmarkLabStore(root: root).upsert([
            evidence("coderBig", stable: false, passed: 0, tps: nil),      // measured broken
            evidence("coderSmall", stable: true, passed: 5, tps: 120)      // measured good
        ])

        let d = scheduler.decide(request: CapabilityRequest(goal: .coding, quality: .high),
                                 installs: [bigBroken, smallGood], host: host(gb: 64),
                                 root: root, appleAvailable: false)
        #expect(d.selectedModelID == "coderSmall")   // measured evidence overrides the size-proxy guess
        #expect(d.rationale.contains { $0.contains("measured") })
    }

    @Test
    func measuredEvidenceIsSurfacedInRationale() throws {
        let root = PersistenceRoot(rootURL: tempDir())
        let coder = install(id: "coder7b", name: "Qwen2.5-Coder-7B", gib: 4.3)
        _ = try ModelBenchmarkLabStore(root: root).upsert([evidence("coder7b", stable: true, passed: 5, tps: 90)])
        let d = scheduler.decide(request: CapabilityRequest(goal: .coding, quality: .balanced),
                                 installs: [coder], host: host(gb: 32), root: root, appleAvailable: false)
        #expect(d.selectedModelID == "coder7b")
        #expect(d.rationale.contains { $0.contains("benchmark lab") })
    }

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
