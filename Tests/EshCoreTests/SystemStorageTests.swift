import Foundation
import Testing
@testable import EshCore

// Cross-filesystem free-capacity selection (exFAT / non-APFS fix). The important-usage key returns 0 on
// non-APFS volumes, which previously masked hundreds of GB of real free space and blocked installs.
@Suite
struct SystemStorageTests {
    private let gb: Int64 = 1_073_741_824

    // Case A — both meaningful → prefer importantUsage.
    @Test func caseA_prefersImportantUsageWhenPositive() {
        #expect(SystemStorage.selectAvailableBytes(importantUsage: 400 * gb, ordinaryAvailable: 521 * gb) == 400 * gb)
    }

    // Case B — the reported production bug: exFAT importantUsage == 0, ordinary huge → use ordinary.
    @Test func caseB_exFATZeroImportantUsageFallsBackToOrdinary() {
        let bytes = SystemStorage.selectAvailableBytes(importantUsage: 0, ordinaryAvailable: 521 * gb)
        #expect(bytes == 521 * gb)
        #expect((bytes ?? 0) > 0)
    }

    // Case C — importantUsage unavailable, ordinary positive → ordinary.
    @Test func caseC_importantUsageUnavailableUsesOrdinary() {
        #expect(SystemStorage.selectAvailableBytes(importantUsage: nil, ordinaryAvailable: 250 * gb) == 250 * gb)
    }

    // Case D — genuinely full → 0 preserved (never "unknown").
    @Test func caseD_genuinelyFullReturnsZeroNotUnknown() {
        #expect(SystemStorage.selectAvailableBytes(importantUsage: 0, ordinaryAvailable: 0) == 0)
    }

    // Neither readable → unknown (nil), so callers can choose not to hard-block.
    @Test func neitherReadableIsUnknown() {
        #expect(SystemStorage.selectAvailableBytes(importantUsage: nil, ordinaryAvailable: nil) == nil)
    }

    // A negative ordinary reading is clamped, not propagated.
    @Test func negativeOrdinaryIsClamped() {
        #expect(SystemStorage.selectAvailableBytes(importantUsage: 0, ordinaryAvailable: -5) == 0)
    }

    // Real probe of a known-good local directory returns a positive snapshot (this repo's temp volume).
    @Test func snapshotOfTempDirIsPositive() {
        let snap = SystemStorage.snapshot(at: FileManager.default.temporaryDirectory)
        #expect(snap != nil)
        #expect((snap?.availableBytes ?? 0) > 0)
    }
}
