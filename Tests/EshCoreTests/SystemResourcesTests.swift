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
}
