import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Supplies the current `DeviceProfile`. Injectable so Model Fit / tests can run against a fixed profile
/// without touching real hardware.
public protocol DeviceProfileProviding: Sendable {
    func currentProfile() -> DeviceProfile
}

/// Reads an honest `DeviceProfile` from the OS. Platform-aware where the semantics genuinely differ
/// (available memory), otherwise shared. Never fabricates a value it cannot read — those come back `nil`.
public struct SystemDeviceProfileProvider: DeviceProfileProviding {
    /// The app-sandbox directory whose volume free space is reported (defaults to esh's assets root).
    private let storageProbeURL: URL

    public init(storageProbeURL: URL? = nil) {
        self.storageProbeURL = storageProbeURL ?? PersistenceRoot.default().assetsRootURL
    }

    public func currentProfile() -> DeviceProfile {
        let info = ProcessInfo.processInfo
        let (available, kind) = Self.availableMemory()
        return DeviceProfile(
            platform: Self.platform,
            physicalMemoryBytes: info.physicalMemory,
            availableMemoryBytes: available,
            availableMemoryKind: kind,
            availableStorageBytes: Self.availableStorage(at: storageProbeURL),
            thermalState: Self.map(info.thermalState),
            lowPowerModeEnabled: info.isLowPowerModeEnabled,
            supportsAppleFoundationModels: AppleIntelligenceService().status().available,
            osVersion: info.operatingSystemVersionString,
            deviceModel: Self.deviceModel()
        )
    }

    static var platform: DevicePlatform {
        #if os(iOS)
        return .iOS
        #elseif os(macOS)
        return .macOS
        #elseif os(visionOS)
        return .visionOS
        #elseif os(tvOS)
        return .tvOS
        #elseif os(watchOS)
        return .watchOS
        #else
        return .other
        #endif
    }

    /// Honest available-memory reading per platform. iOS/tvOS/watchOS/visionOS report the memory available
    /// to THIS process before jetsam (`os_proc_available_memory`); macOS reports system-wide available
    /// memory (via the existing mach probe). Anything unreadable is `(nil, .unknown)`.
    static func availableMemory() -> (UInt64?, MemoryReadingKind) {
        #if os(macOS)
        if let snap = SystemMemory.snapshot(), snap.availableBytes >= 0 {
            return (UInt64(snap.availableBytes), .systemAvailable)
        }
        return (nil, .unknown)
        #elseif os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        let bytes = os_proc_available_memory()   // size_t; 0 when unavailable
        return bytes > 0 ? (UInt64(bytes), .processAvailable) : (nil, .unknown)
        #else
        return (nil, .unknown)
        #endif
    }

    /// Free storage usable for model installation, in the given sandbox directory. Uses
    /// `volumeAvailableCapacityForImportantUsage` (the value Apple recommends for "can I download this?").
    static func availableStorage(at url: URL) -> UInt64? {
        let probe = (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil ? url : url.deletingLastPathComponent()
        if let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let bytes = values.volumeAvailableCapacityForImportantUsage, bytes >= 0 {
            return UInt64(bytes)
        }
        return nil
    }

    static func map(_ thermal: ProcessInfo.ThermalState) -> ThermalState? {
        switch thermal {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return nil
        }
    }

    static func deviceModel() -> String? {
        #if os(macOS)
        return sysctlString("hw.model")
        #else
        // On a real iOS device this is the marketing model id (e.g. "iPhone18,3"); on the Simulator it is
        // the host arch ("arm64"), which is honest — the profile is describing the run environment.
        return sysctlString("hw.machine")
        #endif
    }

    private static func sysctlString(_ name: String) -> String? {
        #if canImport(Darwin)
        var size = size_t(0)
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #else
        return nil
        #endif
    }
}

// MARK: - Bridge into the existing Model Fit

public extension HostMachineProfile {
    /// Map a platform-neutral `DeviceProfile` into the profile the existing `ModelFitService` consumes,
    /// so there is ONE Model Fit. Uses measured memory where available; leaves fields `nil`/absent rather
    /// than inventing values. The safe budget mirrors `HostMachineProfileService`'s reserve policy.
    init(deviceProfile p: DeviceProfile) {
        let totalGB = p.physicalMemoryGB
        let availableGB = p.availableMemoryGB
        var warnings: [String] = []
        var safeBudgetGB: Double?
        if let availableGB {
            let reserveGB = max(4.0, totalGB * 0.2)
            let availabilityAdjustedGB = max(0, availableGB - max(2.0, reserveGB * 0.5))
            safeBudgetGB = max(0, min(totalGB - reserveGB, availabilityAdjustedGB))
            if availableGB < reserveGB { warnings.append("Current available memory is under the usual safety margin.") }
        } else {
            warnings.append("Available memory is unknown on this platform (\(p.availableMemoryKind.rawValue)); fit is based on total memory only.")
        }
        if p.thermalState == .serious || p.thermalState == .critical {
            warnings.append("Device is under thermal pressure (\(p.thermalState!.rawValue)); prefer a smaller model or defer heavy work.")
        }
        if p.lowPowerModeEnabled == true {
            warnings.append("Low Power Mode is on; runtime should be conservative.")
        }
        self.init(
            machineModel: p.deviceModel,
            chipDescription: nil,
            totalMemoryGB: totalGB,
            availableMemoryGB: availableGB,
            safeBudgetGB: safeBudgetGB,
            warnings: warnings
        )
    }
}
