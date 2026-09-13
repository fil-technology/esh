import Foundation
import Testing
@testable import EshCore

private let GB: UInt64 = 1_073_741_824

private func profile(physicalGB: Double, availableGB: Double?, kind: MemoryReadingKind,
                     thermal: ThermalState? = .nominal, lowPower: Bool? = false,
                     appleFM: Bool = true) -> DeviceProfile {
    DeviceProfile(
        platform: .iOS,
        physicalMemoryBytes: UInt64(physicalGB * Double(GB)),
        availableMemoryBytes: availableGB.map { UInt64($0 * Double(GB)) },
        availableMemoryKind: kind,
        availableStorageBytes: 32 * GB,
        thermalState: thermal,
        lowPowerModeEnabled: lowPower,
        supportsAppleFoundationModels: appleFM,
        osVersion: "Version 26.6.2 (Build 23G90)",
        deviceModel: "iPhone18,3"
    )
}

@Suite
struct DeviceProfileTests {

    @Test
    func constructionAndGBAccessorsDistinguishKnownFromUnknown() {
        let known = profile(physicalGB: 8, availableGB: 3, kind: .processAvailable)
        #expect(known.physicalMemoryGB == 8)
        #expect(known.availableMemoryGB == 3)
        #expect(known.availableStorageGB == 32)

        // Unknown available memory must stay nil — never fabricated.
        let unknown = profile(physicalGB: 8, availableGB: nil, kind: .unknown)
        #expect(unknown.availableMemoryBytes == nil)
        #expect(unknown.availableMemoryGB == nil)
        #expect(unknown.availableMemoryKind == .unknown)
    }

    @Test
    func thermalStateMappingCoversAllKnownStates() {
        #expect(SystemDeviceProfileProvider.map(.nominal) == .nominal)
        #expect(SystemDeviceProfileProvider.map(.fair) == .fair)
        #expect(SystemDeviceProfileProvider.map(.serious) == .serious)
        #expect(SystemDeviceProfileProvider.map(.critical) == .critical)
    }

    @Test
    func hostProfileBridgeUsesMeasuredMemoryAndComputesSafeBudget() {
        let host = HostMachineProfile(deviceProfile: profile(physicalGB: 16, availableGB: 10, kind: .processAvailable))
        #expect(host.totalMemoryGB == 16)
        #expect(host.availableMemoryGB == 10)
        #expect((host.safeBudgetGB ?? 0) > 0)
        #expect(host.machineModel == "iPhone18,3")
    }

    @Test
    func hostProfileBridgeIsHonestWhenAvailableMemoryUnknown() {
        let host = HostMachineProfile(deviceProfile: profile(physicalGB: 8, availableGB: nil, kind: .unknown))
        #expect(host.totalMemoryGB == 8)
        #expect(host.availableMemoryGB == nil)
        #expect(host.safeBudgetGB == nil)                       // not invented
        #expect(host.warnings.contains { $0.contains("unknown") })
    }

    @Test
    func hostProfileBridgeWarnsUnderThermalAndLowPowerPressure() {
        let hot = HostMachineProfile(deviceProfile: profile(physicalGB: 8, availableGB: 4, kind: .processAvailable, thermal: .serious))
        #expect(hot.warnings.contains { $0.contains("thermal") })
        let lp = HostMachineProfile(deviceProfile: profile(physicalGB: 8, availableGB: 4, kind: .processAvailable, lowPower: true))
        #expect(lp.warnings.contains { $0.lowercased().contains("low power") })
    }

    // The EXISTING Model Fit consumes a DeviceProfile (via HostMachineProfile) — no separate MobileModelFit.
    @Test
    func existingModelFitConsumesDeviceProfileAndReflectsConstraints() {
        let fit = ModelFitService()
        let root = PersistenceRoot.default()
        // A ~7B fp16 model needs well over 10 GB at runtime.
        let input = ModelFitService.Input(parameterCountB: 7, effectiveBits: 16, format: .gguf,
                                          backend: .gguf, contextTokens: 4096)
        let constrained = fit.assess(input: input, host: HostMachineProfile(deviceProfile: profile(physicalGB: 2, availableGB: 1, kind: .processAvailable)), root: root)
        let roomy = fit.assess(input: input, host: HostMachineProfile(deviceProfile: profile(physicalGB: 64, availableGB: 48, kind: .systemAvailable)), root: root)

        // The profile flows through: usable memory tracks the device.
        #expect((constrained.usableMemoryGB ?? .greatestFiniteMagnitude) < (roomy.usableMemoryGB ?? 0))
        // And the fit verdict is worse on the constrained device.
        #expect([.tight, .unlikely].contains(constrained.fitClass))
        #expect([.comfortable, .fits].contains(roomy.fitClass))
    }

    @Test
    func runtimePressureEventsAreEquatable() {
        #expect(RuntimePressureEvent.memoryWarning == .memoryWarning)
        #expect(RuntimePressureEvent.thermalStateChanged(.serious) == .thermalStateChanged(.serious))
        #expect(RuntimePressureEvent.thermalStateChanged(.serious) != .thermalStateChanged(.critical))
        #expect(RuntimePressureEvent.lowPowerModeChanged(true) != .lowPowerModeChanged(false))
    }

    // The real system provider returns an honest profile on the host (macOS here): physical memory is
    // always known; available memory is systemAvailable on macOS.
    @Test
    func systemProviderReturnsHonestProfileOnHost() {
        let p = SystemDeviceProfileProvider().currentProfile()
        #expect(p.physicalMemoryBytes > 0)
        #expect(!p.osVersion.isEmpty)
        #if os(macOS)
        #expect(p.platform == .macOS)
        if p.availableMemoryBytes != nil { #expect(p.availableMemoryKind == .systemAvailable) }
        #endif
    }
}
