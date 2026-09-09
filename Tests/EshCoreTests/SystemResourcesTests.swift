import Foundation
import Testing
@testable import EshCore

@Suite
struct SystemResourcesTests {
    @Test
    func snapshotReportsSaneMemoryAndOptionalGPU() {
        let r = SystemResourcesSnapshot.current()
        #expect(r.totalMemoryBytes > 0)
        #expect(r.usedMemoryBytes >= 0)
        #expect(r.usedMemoryBytes <= r.totalMemoryBytes)
        #expect(r.availableMemoryBytes >= 0)
        // GPU utilization is best-effort: nil when unreadable, otherwise a percentage in [0, 100].
        if let gpu = r.gpuUtilizationPercent { #expect(gpu >= 0 && gpu <= 100) }
    }

    @Test
    func memoryPreflightRefusesOnlyWhenShort() {
        // A tiny requirement always fits → nil (proceed). An impossible one never fits → an actionable string.
        #expect(HeavyTaskMemory.insufficientMemoryMessage(neededGB: 0, label: "image editing") == nil)
        let msg = HeavyTaskMemory.insufficientMemoryMessage(neededGB: 1_000_000, label: "image editing")
        #expect(msg != nil)
        #expect(msg?.contains("Not enough free memory to start image editing") == true)
        #expect(msg?.contains("GB needed") == true)
    }

    @Test
    func topConsumerIsSaneWhenPresent() {
        // Best-effort: nil is acceptable (probe unavailable), but any result must be a real positive size.
        if let c = SystemProcesses.topConsumer() {
            #expect(!c.name.isEmpty)
            #expect(c.gigabytes >= 0.5)
        }
    }
}
