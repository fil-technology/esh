import Foundation
import Testing
@testable import EshCore

@Suite
struct SystemStorageTests {
    @Test
    func reportsPositiveFreeSpaceForARealVolume() {
        // The running volume always has some capacity; the snapshot must be non-nil and positive
        // (regressions here — e.g. returning a 0 ForImportantUsage value on ExFAT — read as "disk
        // full" and would block downloads / Model Fit).
        let snap = SystemStorage.snapshot(at: FileManager.default.temporaryDirectory)
        #expect(snap != nil)
        #expect((snap?.availableBytes ?? 0) > 0)
    }
}
