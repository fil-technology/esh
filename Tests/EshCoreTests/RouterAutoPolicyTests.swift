import Foundation
import Testing
@testable import EshCore

@Suite
struct RouterAutoPolicyTests {
    private func ev(_ router: String, mode: String, score: Double, falseExec: Double = 0, available: Bool = true,
                   schema: Int = CapabilitySchemaVersion.current, dataset: Int = RoutingBenchmark.datasetVersion,
                   os: String? = nil) -> RouterEvidence {
        RouterEvidence(router: router, mode: mode, available: available, total: 58,
                       capabilitySelectionAccuracy: 0.5, falseExecutionRate: falseExec, conservativeScore: score,
                       hardware: "M1 Pro", osVersion: os, capabilitySchemaVersion: schema, datasetVersion: dataset,
                       dateISO8601: "2026-09-03T00:00:00Z")
    }
    private let policy = RouterAutoPolicy()
    private func choose(_ e: [RouterEvidence]) -> RouterAutoPolicy.Decision {
        policy.choose(from: e, currentSchemaVersion: CapabilitySchemaVersion.current,
                      currentDatasetVersion: RoutingBenchmark.datasetVersion, currentOS: "macOS26")
    }

    @Test
    func staysOnTier0WhenNoTier1BeatsTheBaseline() {
        // Real measured shape: tier0 -0.14, resident tier1 -1.79 → Router Auto keeps Tier-0 (nil).
        let d = choose([ev("tier0", mode: "tier0", score: -0.14), ev("resident-llm", mode: "tier1", score: -1.79)])
        #expect(d.chosenRouter == nil)
        #expect(d.reasons.contains { $0.contains("resident-llm") && $0.contains("not worth") })
    }

    @Test
    func choosesATier1RouterThatBeatsTheBaselineAndIsSafe() {
        let d = choose([ev("tier0", mode: "tier0", score: -0.14),
                        ev("functiongemma", mode: "tier1", score: 0.6, falseExec: 0.0)])
        #expect(d.chosenRouter == "functiongemma")
    }

    @Test
    func rejectsAHighFalseExecutionRouterEvenIfScoreIsHigh() {
        let d = choose([ev("tier0", mode: "tier0", score: -0.14),
                        ev("risky", mode: "tier1", score: 0.9, falseExec: 0.10)])   // 10% false-exec > ceiling
        #expect(d.chosenRouter == nil)
    }

    @Test
    func rejectsStaleEvidence() {
        let d = choose([ev("tier0", mode: "tier0", score: -0.14),
                        ev("apple-foundation", mode: "tier1", score: 0.7, os: "macOS25")])  // stale OS
        #expect(d.chosenRouter == nil)
        #expect(d.reasons.contains { $0.contains("stale") })
    }

    @Test
    func prefersHigherScoreAmongEligible() {
        let d = choose([ev("tier0", mode: "tier0", score: -0.14),
                        ev("a", mode: "tier1", score: 0.5), ev("b", mode: "tier1", score: 0.8)])
        #expect(d.chosenRouter == "b")
    }

    @Test
    func evidenceStoreRoundTrips() throws {
        let root = PersistenceRoot(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("esh-rev-\(UUID().uuidString)"))
        let store = RouterEvidenceStore(root: root)
        _ = try store.upsert(ev("resident-llm", mode: "tier1", score: -1.79))
        let ds = try store.upsert(ev("resident-llm", mode: "tier1", score: -1.5))  // same key → replaces
        #expect(ds.evidence.count == 1)
        #expect(store.load().evidence.first?.conservativeScore == -1.5)
    }
}
