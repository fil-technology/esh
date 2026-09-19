import Foundation
import Testing
@testable import EshCore

// rc.21 — resident-model inspection at the registry layer: truthful snapshot, measured-vs-estimated memory,
// and idle (unloadable) filtering. Pure: mock providers, no MLX.

private let GB = 1_073_741_824.0

private final class MockResidentProvider: CapabilityProvider, ResourceStateReporting, @unchecked Sendable {
    let descriptor: CapabilityProviderDescriptor
    let box: ProviderStateBox
    init(id: String, capability: CapabilityID, estimatedGB: Double?, warm: Bool, active: Bool = false) {
        let profile = estimatedGB.map { CapabilityResourceProfile(estimatedPeakMemoryGB: $0, qualityTier: 100) }
        descriptor = CapabilityProviderDescriptor(
            id: id, capabilities: [capability], acceptedInputs: [.text], producedOutputs: [.image],
            backend: .mlx, modelFamily: "\(id)-family", resourceProfile: profile)
        box = ProviderStateBox(ProviderRuntimeState(installed: true, warm: warm, active: active))
    }
    var resourceState: ProviderRuntimeState { box.state }
    func execute(_ r: ResolvedExecutionRequest, context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func unload() async { box.setWarm(false) }
}

/// A provider with no runtime-state reporting — must never appear in resident snapshots.
private struct OpaqueProvider: CapabilityProvider {
    let descriptor = CapabilityProviderDescriptor(id: "opaque", capabilities: [.imageOCR],
        acceptedInputs: [.image], producedOutputs: [.text], backend: .appleVision)
    func execute(_ r: ResolvedExecutionRequest, context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite struct ResourceInspectionTests {
    @Test func residentSnapshotReportsOnlyWarmReportingProviders() {
        var reg = CapabilityRegistry()
        reg.register(MockResidentProvider(id: "warm", capability: .imageEdit, estimatedGB: 14, warm: true))
        reg.register(MockResidentProvider(id: "cold", capability: .imageGenerate, estimatedGB: 8, warm: false))
        reg.register(MockResidentProvider(id: "busy", capability: .imageRestyle, estimatedGB: 6, warm: true, active: true))
        reg.register(OpaqueProvider())  // no ResourceStateReporting → never resident

        let resident = reg.residentModels()
        let ids = Set(resident.map(\.id))
        #expect(ids == ["warm", "busy"])                 // cold + opaque excluded
        #expect(resident.first { $0.id == "warm" }?.residency == .warm)
        #expect(resident.first { $0.id == "busy" }?.residency == .active)
        #expect(resident.first { $0.id == "warm" }?.capability == .imageEdit)
        #expect(resident.first { $0.id == "warm" }?.modelID == "warm-family")
    }

    @Test func measuredMemoryIsNeverSynthesizedFromEstimate() {
        var reg = CapabilityRegistry()
        reg.register(MockResidentProvider(id: "pm", capability: .imageEdit, estimatedGB: 14, warm: true))
        let model = reg.residentModels().first { $0.id == "pm" }!
        // Estimate is surfaced, clearly distinct; measured stays nil (esh did not measure it).
        #expect(model.estimatedPeakMemoryBytes == Int64(14 * GB))
        #expect(model.measuredMemoryBytes == nil)
    }

    @Test func residentWithoutProfileHasNilEstimate() {
        var reg = CapabilityRegistry()
        reg.register(MockResidentProvider(id: "noprofile", capability: .imageEdit, estimatedGB: nil, warm: true))
        let model = reg.residentModels().first { $0.id == "noprofile" }!
        #expect(model.estimatedPeakMemoryBytes == nil)
        #expect(model.measuredMemoryBytes == nil)
    }

    @Test func idleUnloadableExcludesActive() {
        var reg = CapabilityRegistry()
        reg.register(MockResidentProvider(id: "idle", capability: .imageEdit, estimatedGB: 14, warm: true))
        reg.register(MockResidentProvider(id: "active", capability: .imageGenerate, estimatedGB: 8, warm: true, active: true))
        #expect(reg.idleUnloadableProviderIDs() == ["idle"])
    }
}
