import Testing
@testable import EshCore

@Suite
struct MemorySafetyPreflightTests {
    // Reference machine: 32 GB M1 Pro.
    private func host(avail: Double?, systemFree: Double?, total: Double = 32, critical: Bool = false) -> HostResources {
        HostResources(totalMemoryGB: total, availableMemoryGB: avail, systemVolumeFreeGB: systemFree,
                      assetsVolumeFreeGB: 400, assetsVolumeAvailable: true, residentHeavyMemoryGB: 0,
                      memoryCritical: critical)
    }

    @Test func smallModelNeverGated() {
        // Even a hostile host can't block a trivially small model (existing lightweight flows stay unaffected).
        let v = MemorySafetyPreflight.evaluate(requiredPeakGB: 2.0, host: host(avail: 0.5, systemFree: 0.2))
        #expect(v.fits)
    }

    @Test func eightyBFitsWithFreshHeadroom() {
        // Post-reboot state measured in Phase C: ~24 GB available, ~16 GB internal free. 80B @ ~22 GB loads safe.
        let v = MemorySafetyPreflight.evaluate(requiredPeakGB: 22.0, host: host(avail: 24, systemFree: 16))
        #expect(v.fits)
    }

    @Test func eightyBRejectedWhenSwapCannotGrow() {
        // The pre-reboot near-miss: swap ~maxed, internal volume ~0.3 GB free. Loading 22 GB would thrash/hang.
        // Must reject with a reason — and must NOT tell the user to reboot.
        let v = MemorySafetyPreflight.evaluate(requiredPeakGB: 22.0, host: host(avail: 14, systemFree: 0.3))
        guard case let .gated(reason, req, _) = v else { Issue.record("expected gated, got \(v)"); return }
        #expect(req == 22.0)
        #expect(reason.lowercased().contains("no reboot"))
        #expect(reason.lowercased().contains("swap") || reason.lowercased().contains("disk"))
    }

    @Test func rejectsModelLargerThanTotalMemory() {
        let v = MemorySafetyPreflight.evaluate(requiredPeakGB: 40.0, host: host(avail: 20, systemFree: 50))
        guard case .gated = v else { Issue.record("expected gated for >total model"); return }
    }

    @Test func rejectsUnderCriticalPressure() {
        let v = MemorySafetyPreflight.evaluate(requiredPeakGB: 18.0, host: host(avail: 20, systemFree: 40, critical: true))
        guard case .gated = v else { Issue.record("expected gated under critical pressure"); return }
    }

    @Test func moderateDeficitWithAmpleDiskFits() {
        // Slightly over available but plenty of disk for a small swap spill, modest deficit → allowed.
        let v = MemorySafetyPreflight.evaluate(requiredPeakGB: 18.0, host: host(avail: 16, systemFree: 60))
        #expect(v.fits)
    }

    @Test func unmeasurableAvailabilityDoesNotFabricateDanger() {
        // availableMemoryGB nil → conservative total*0.6 (≈19.2 on 32 GB); a 16 GB model with ample disk fits.
        let v = MemorySafetyPreflight.evaluate(requiredPeakGB: 16.0, host: host(avail: nil, systemFree: 100))
        #expect(v.fits)
    }
}
