import Foundation
import Testing
import EshCore
@testable import EshImageGen

// Real-machine routing dogfood for the image.edit tiers. Reads the LIVE machine (physical + available
// memory, internal/system-volume free = swap headroom, assets-volume free) via the same probe the runtime
// uses, then runs the real ResourceScheduler with the shipping PhotoMaker + InstructPix2Pix profiles. Fast:
// no weights download, no MLX. Validates that the wired profiles + live detection produce a coherent,
// explainable decision on THIS machine, and (deterministically) that a nearly-full internal disk forces the
// documented fallback even when the assets volume is huge.

@Suite struct ResourceRoutingDogfoodTests {
    private let sched = ResourceScheduler()
    private func liveCandidates(_ state: ProviderRuntimeState = .init(installed: true)) -> [ResourceCandidate] {
        [ResourceCandidate(providerID: EshImageEdit.defaultTierProviderID, profile: EshImageEdit.resourceProfile, state: state),
         ResourceCandidate(providerID: EshPhotoMaker.providerID, profile: EshPhotoMaker.resourceProfile, state: state)]
    }

    @Test func realMachineProducesExplainableDecision() {
        let host = HostResourceProbe.snapshot(root: .default())
        print("""
        [resource-routing dogfood] live host:
          totalMem=\(host.totalMemoryGB) GB  availMem=\(host.availableMemoryGB.map { "\($0)" } ?? "nil") GB
          systemVolFree(swap headroom)=\(host.systemVolumeFreeGB.map { "\($0)" } ?? "nil") GB
          assetsVolFree=\(host.assetsVolumeFreeGB.map { "\($0)" } ?? "nil") GB  assetsAvailable=\(host.assetsVolumeAvailable)
        """)
        let auto = sched.select(capability: "image.edit", explicit: false, candidates: liveCandidates(),
                                host: host, policy: .default)
        switch auto {
        case let .selected(id, diag): print("[resource-routing dogfood] Auto → \(id): \(diag.reason)")
        case let .gated(gate, _): print("[resource-routing dogfood] Auto → GATED: \(gate.message)")
        case let .passthrough(reason): print("[resource-routing dogfood] Auto → passthrough: \(reason)")
        }
        // The decision must be one of the coherent outcomes (never a crash / empty).
        if case .passthrough = auto { Issue.record("both tiers declare profiles; passthrough is unexpected") }
    }

    // Deterministic reproduction of the real incident: internal/system volume nearly full, external SSD huge.
    @Test func nearlyFullInternalDiskForcesFallbackThenGate() {
        // 32 GB machine. System volume 14 GB free → PhotoMaker (needs 18) gated, IP2P (needs 12) fits.
        let mid = HostResources(totalMemoryGB: 32, availableMemoryGB: 24, systemVolumeFreeGB: 14, assetsVolumeFreeGB: 600)
        guard case let .selected(id, _) = sched.select(capability: "image.edit", explicit: false,
              candidates: liveCandidates(), host: mid, policy: .default) else { Issue.record("expected fallback"); return }
        #expect(id == EshImageEdit.defaultTierProviderID)

        // Squeeze the internal volume below even the light tier → typed Auto gate (no OOM, no swap-death).
        let tight = HostResources(totalMemoryGB: 32, availableMemoryGB: 24, systemVolumeFreeGB: 4, assetsVolumeFreeGB: 600)
        guard case let .gated(gate, _) = sched.select(capability: "image.edit", explicit: false,
              candidates: liveCandidates(), host: tight, policy: .default) else { Issue.record("expected gate"); return }
        #expect(gate.reason.contains("system-volume") || gate.reason.contains("memory"))
    }
}
