import Foundation
import Testing
@testable import EshCore

// The generic resource-aware Auto routing validation matrix (deliverable 12). Pure: synthetic hosts,
// profiles and policies — no device, no MLX. Covers the fit evaluator (memory / per-volume disk / swap
// headroom / download+offline policy / warm reuse) and the scheduler (Auto quality ranking, explicit
// honor-or-gate, fallback, anti-flapping tie-breaks, explainable routing).

private let GB = 1_073_741_824.0

private func profile(peak: Double, downloadGB: Double = 4, installedGB: Double = 4, sysHead: Double,
                     assetsHead: Double = 2, tier: Int, latency: LatencyClass = .moderate) -> CapabilityResourceProfile {
    CapabilityResourceProfile(estimatedPeakMemoryGB: peak,
        modelDownloadBytes: Int64(downloadGB * GB), installedBytes: Int64(installedGB * GB),
        temporaryInstallBytes: Int64(1 * GB), minimumSystemVolumeHeadroomGB: sysHead,
        minimumAssetsVolumeHeadroomGB: assetsHead, qualityTier: tier, latencyClass: latency)
}

// Representative tiers under test.
private var photoMaker: CapabilityResourceProfile { profile(peak: 14, downloadGB: 10, installedGB: 10, sysHead: 18, assetsHead: 3, tier: 100, latency: .slow) }
private var ip2p: CapabilityResourceProfile { profile(peak: 8, downloadGB: 2, installedGB: 2, sysHead: 12, assetsHead: 2, tier: 50, latency: .moderate) }

@Suite struct ResourceFitEvaluatorTests {
    let eval = ResourceFitEvaluator()

    // 1. Ample machine: everything fits.
    @Test func amplyProvisionedFits() {
        let host = HostResources(totalMemoryGB: 64, availableMemoryGB: 50, systemVolumeFreeGB: 200,
                                 assetsVolumeFreeGB: 500)
        #expect(eval.evaluate(profile: photoMaker, installed: true, warm: false, host: host, policy: .default).fits)
        #expect(eval.evaluate(profile: ip2p, installed: true, warm: false, host: host, policy: .default).fits)
    }

    // 2. THE real case: weights fit the SSD (assets volume huge) but the internal/system volume is nearly
    //    full → swap headroom insufficient → the heavy tier is gated; the lighter tier may still fit.
    @Test func swapHeadroomGatesEvenWhenAssetsVolumeHasRoom() {
        let host = HostResources(totalMemoryGB: 32, availableMemoryGB: 24, systemVolumeFreeGB: 6,
                                 assetsVolumeFreeGB: 600)
        let pm = eval.evaluate(profile: photoMaker, installed: true, warm: false, host: host, policy: .default)
        #expect(!pm.fits)
        if case let .gated(reason, _, _) = pm { #expect(reason.contains("system-volume")) }
        // IP2P needs 12 GB system headroom, still gated at 6 GB free.
        #expect(!eval.evaluate(profile: ip2p, installed: true, warm: false, host: host, policy: .default).fits)
    }

    // 3. Insufficient memory gates independently of disk.
    @Test func insufficientMemoryGates() {
        let host = HostResources(totalMemoryGB: 16, availableMemoryGB: 10, systemVolumeFreeGB: 200,
                                 assetsVolumeFreeGB: 500)
        let v = eval.evaluate(profile: photoMaker, installed: true, warm: false, host: host, policy: .default)
        #expect(!v.fits)
        if case let .gated(reason, _, _) = v { #expect(reason.contains("memory")) }
    }

    // 4. Warm reuse is NOT falsely gated: a resident model dips available memory, but warm adds its share
    //    back so re-use stays eligible.
    @Test func warmReuseNotFalselyGated() {
        // 32 GB machine, PhotoMaker resident so only 6 GB shows available; peak 14 GB.
        let host = HostResources(totalMemoryGB: 32, availableMemoryGB: 6, systemVolumeFreeGB: 60,
                                 assetsVolumeFreeGB: 500)
        #expect(!eval.evaluate(profile: photoMaker, installed: true, warm: false, host: host, policy: .default).fits)
        #expect(eval.evaluate(profile: photoMaker, installed: true, warm: true, host: host, policy: .default).fits)
    }

    // 5. Not-installed + offline / downloads disabled → gated on the download.
    @Test func offlineGatesUninstalledModel() {
        let host = HostResources(totalMemoryGB: 64, availableMemoryGB: 50, systemVolumeFreeGB: 200, assetsVolumeFreeGB: 500)
        let offline = ResourcePolicy(allowDownload: false)
        let v = eval.evaluate(profile: photoMaker, installed: false, warm: false, host: host, policy: offline)
        #expect(!v.fits)
        if case let .gated(reason, _, _) = v { #expect(reason.contains("download")) }
        // Installed model is unaffected by the offline policy.
        #expect(eval.evaluate(profile: photoMaker, installed: true, warm: false, host: host, policy: offline).fits)
    }

    // 6. Not-installed but assets volume too small for the download → gated.
    @Test func downloadSpaceGates() {
        let host = HostResources(totalMemoryGB: 64, availableMemoryGB: 50, systemVolumeFreeGB: 200, assetsVolumeFreeGB: 5)
        #expect(!eval.evaluate(profile: photoMaker, installed: false, warm: false, host: host, policy: .default).fits)
        // IP2P (2 GB) still doesn't fit in 5 GB once staging + headroom are added? 2+1+2=5, needs 5, has 5 → fits.
        #expect(eval.evaluate(profile: ip2p, installed: false, warm: false, host: host, policy: .default).fits)
    }

    // 7. Assets volume disconnected → gated (external SSD unplugged).
    @Test func assetsVolumeUnavailableGates() {
        let host = HostResources(totalMemoryGB: 64, availableMemoryGB: 50, systemVolumeFreeGB: 200,
                                 assetsVolumeFreeGB: nil, assetsVolumeAvailable: false)
        #expect(!eval.evaluate(profile: ip2p, installed: true, warm: false, host: host, policy: .default).fits)
    }

    // 8. maxMemoryGB caller policy tightens the budget.
    @Test func callerMaxMemoryTightensBudget() {
        let host = HostResources(totalMemoryGB: 64, availableMemoryGB: 50, systemVolumeFreeGB: 200, assetsVolumeFreeGB: 500)
        let capped = ResourcePolicy(maxMemoryGB: 12, reserveMemoryGB: 2)
        #expect(!eval.evaluate(profile: photoMaker, installed: true, warm: false, host: host, policy: capped).fits) // 14 > 12-2
        #expect(eval.evaluate(profile: ip2p, installed: true, warm: false, host: host, policy: capped).fits)        // 8 <= 10
    }

    // 9. Critical memory pressure gates regardless of headroom.
    @Test func criticalPressureGates() {
        let host = HostResources(totalMemoryGB: 64, availableMemoryGB: 50, systemVolumeFreeGB: 200,
                                 assetsVolumeFreeGB: 500, memoryCritical: true)
        #expect(!eval.evaluate(profile: ip2p, installed: true, warm: true, host: host, policy: .default).fits)
    }
}

@Suite struct ResourceSchedulerTests {
    let sched = ResourceScheduler()
    let cap = "image.edit"

    private func candidates(_ pmState: ProviderRuntimeState = .init(installed: true),
                            _ ipState: ProviderRuntimeState = .init(installed: true)) -> [ResourceCandidate] {
        // Native-first order = IP2P registered first (as in the real registry), PhotoMaker second.
        [ResourceCandidate(providerID: "mlx-instruct-image-edit", profile: ip2p, state: ipState),
         ResourceCandidate(providerID: "mlx-photomaker-v1", profile: photoMaker, state: pmState)]
    }

    // 10. Auto picks the HIGHEST-quality tier that fits (PhotoMaker over IP2P) — not the first-registered.
    @Test func autoPrefersHighestQualityThatFits() {
        let host = HostResources(totalMemoryGB: 64, availableMemoryGB: 50, systemVolumeFreeGB: 200, assetsVolumeFreeGB: 500)
        let out = sched.select(capability: cap, explicit: false, candidates: candidates(), host: host, policy: .default)
        guard case let .selected(id, diag) = out else { Issue.record("expected selection"); return }
        #expect(id == "mlx-photomaker-v1")
        #expect(diag.reason.contains("highest-quality"))
    }

    // 11. Auto falls back to the lighter tier when the heavy one is gated (swap headroom).
    @Test func autoFallsBackWhenHeavyTierGated() {
        // System volume 14 GB: PhotoMaker needs 18 (gated), IP2P needs 12 (fits).
        let host = HostResources(totalMemoryGB: 32, availableMemoryGB: 24, systemVolumeFreeGB: 14, assetsVolumeFreeGB: 600)
        let out = sched.select(capability: cap, explicit: false, candidates: candidates(), host: host, policy: .default)
        guard case let .selected(id, _) = out else { Issue.record("expected selection"); return }
        #expect(id == "mlx-instruct-image-edit")
    }

    // 12. Auto gates (typed) when NOTHING fits.
    @Test func autoGatesWhenNothingFits() {
        let host = HostResources(totalMemoryGB: 32, availableMemoryGB: 24, systemVolumeFreeGB: 4, assetsVolumeFreeGB: 600)
        let out = sched.select(capability: cap, explicit: false, candidates: candidates(), host: host, policy: .default)
        guard case let .gated(gate, _) = out else { Issue.record("expected gate"); return }
        #expect(gate.providerID == nil)   // Auto: nothing fit
        #expect(!gate.explicit)
    }

    // 13. Explicit pin that fits is honored.
    @Test func explicitPinHonored() {
        let host = HostResources(totalMemoryGB: 64, availableMemoryGB: 50, systemVolumeFreeGB: 200, assetsVolumeFreeGB: 500)
        // candidates(for:) would have filtered to the pin — simulate by passing only PhotoMaker.
        let only = [ResourceCandidate(providerID: "mlx-photomaker-v1", profile: photoMaker, state: .init(installed: true))]
        let out = sched.select(capability: cap, explicit: true, candidates: only, host: host, policy: .default)
        guard case let .selected(id, _) = out else { Issue.record("expected selection"); return }
        #expect(id == "mlx-photomaker-v1")
    }

    // 14. Explicit pin that does NOT fit is gated — NO substitution to the lighter tier.
    @Test func explicitPinGatedNoSubstitution() {
        let host = HostResources(totalMemoryGB: 32, availableMemoryGB: 24, systemVolumeFreeGB: 6, assetsVolumeFreeGB: 600)
        let only = [ResourceCandidate(providerID: "mlx-photomaker-v1", profile: photoMaker, state: .init(installed: true))]
        let out = sched.select(capability: cap, explicit: true, candidates: only, host: host, policy: .default)
        guard case let .gated(gate, _) = out else { Issue.record("expected gate"); return }
        #expect(gate.providerID == "mlx-photomaker-v1")
        #expect(gate.explicit)
    }

    // 15. Anti-flapping: with two equal-quality tiers that both fit, the WARM one wins (stable tie-break),
    //     so routing doesn't oscillate between equivalent providers.
    @Test func warmTierWinsTieBreak() {
        let host = HostResources(totalMemoryGB: 64, availableMemoryGB: 50, systemVolumeFreeGB: 200, assetsVolumeFreeGB: 500)
        let a = ResourceCandidate(providerID: "tier-a", profile: profile(peak: 8, sysHead: 12, tier: 50), state: .init(installed: true, warm: false))
        let b = ResourceCandidate(providerID: "tier-b", profile: profile(peak: 8, sysHead: 12, tier: 50), state: .init(installed: true, warm: true))
        let out = sched.select(capability: cap, explicit: false, candidates: [a, b], host: host, policy: .default)
        guard case let .selected(id, _) = out else { Issue.record("expected selection"); return }
        #expect(id == "tier-b")
    }

    // 16. lowMemory preference picks the smallest-footprint fitting tier over the highest quality.
    @Test func lowMemoryPreferencePicksSmallest() {
        let host = HostResources(totalMemoryGB: 64, availableMemoryGB: 50, systemVolumeFreeGB: 200, assetsVolumeFreeGB: 500)
        let policy = ResourcePolicy(qualityPreference: .lowMemory)
        let out = sched.select(capability: cap, explicit: false, candidates: candidates(), host: host, policy: policy)
        guard case let .selected(id, _) = out else { Issue.record("expected selection"); return }
        #expect(id == "mlx-instruct-image-edit")
    }

    // 17. Unprofiled providers pass through to legacy selection.
    @Test func unprofiledPassthrough() {
        let host = HostResources(totalMemoryGB: 64, availableMemoryGB: 50, systemVolumeFreeGB: 200, assetsVolumeFreeGB: 500)
        let legacy = [ResourceCandidate(providerID: "apple-ocr", profile: nil, state: .init())]
        let out = sched.select(capability: "image.ocr", explicit: false, candidates: legacy, host: host, policy: .default)
        guard case .passthrough = out else { Issue.record("expected passthrough"); return }
    }
}
