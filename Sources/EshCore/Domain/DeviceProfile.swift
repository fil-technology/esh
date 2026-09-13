import Foundation

/// The platform esh is running on. Platform-neutral so Model Fit / scheduling can reason about device
/// class without macOS-specific probes.
public enum DevicePlatform: String, Codable, Hashable, Sendable {
    case iOS
    case macOS
    case visionOS
    case tvOS
    case watchOS
    case other
}

/// Normalized thermal pressure, mapped from `ProcessInfo.ThermalState`. Conservative semantics: higher
/// states mean the runtime should do less work (smaller models, fewer concurrent requests, release caches).
public enum ThermalState: String, Codable, Hashable, Sendable, CaseIterable {
    case nominal
    case fair
    case serious
    case critical
}

/// What an `availableMemoryBytes` reading actually represents — so callers never mistake one platform's
/// number for another's. iOS reports memory available to THIS process before jetsam (`os_proc_available_memory`);
/// macOS reports system-wide available memory. `unknown` means the platform did not give an honest value.
public enum MemoryReadingKind: String, Codable, Hashable, Sendable {
    case processAvailable   // iOS/tvOS/watchOS/visionOS: headroom for this process (os_proc_available_memory)
    case systemAvailable    // macOS: system-wide available memory
    case unknown
}

/// A platform-neutral snapshot of the device/runtime conditions esh is running under. Every value the
/// platform cannot report honestly is `nil` (or `.unknown`) — esh never fabricates precision. Feeds the
/// existing Model Fit via `HostMachineProfile(deviceProfile:)`; on Apple-only iOS the fit is simple today,
/// but the abstraction is ready for future embedded models.
public struct DeviceProfile: Codable, Hashable, Sendable {
    public let platform: DevicePlatform
    /// Total physical RAM (from `ProcessInfo.physicalMemory`). Always available.
    public let physicalMemoryBytes: UInt64
    /// Available memory, meaning per `availableMemoryKind`. `nil` when unavailable.
    public let availableMemoryBytes: UInt64?
    public let availableMemoryKind: MemoryReadingKind
    /// Free storage for model installation in the app sandbox (importantUsage). `nil` when unavailable.
    public let availableStorageBytes: UInt64?
    /// Thermal pressure. `nil` when the platform does not expose it.
    public let thermalState: ThermalState?
    /// Low Power Mode. `nil` when the platform does not expose it.
    public let lowPowerModeEnabled: Bool?
    /// Whether Apple Foundation Models is ready on this device (sourced from `AppleIntelligenceService`).
    public let supportsAppleFoundationModels: Bool
    /// e.g. "Version 26.6.2 (Build 23G90)".
    public let osVersion: String
    /// Best-effort hardware model identifier (e.g. "iPhone18,3"), or `nil`.
    public let deviceModel: String?

    public init(
        platform: DevicePlatform,
        physicalMemoryBytes: UInt64,
        availableMemoryBytes: UInt64?,
        availableMemoryKind: MemoryReadingKind,
        availableStorageBytes: UInt64?,
        thermalState: ThermalState?,
        lowPowerModeEnabled: Bool?,
        supportsAppleFoundationModels: Bool,
        osVersion: String,
        deviceModel: String? = nil
    ) {
        self.platform = platform
        self.physicalMemoryBytes = physicalMemoryBytes
        self.availableMemoryBytes = availableMemoryBytes
        self.availableMemoryKind = availableMemoryKind
        self.availableStorageBytes = availableStorageBytes
        self.thermalState = thermalState
        self.lowPowerModeEnabled = lowPowerModeEnabled
        self.supportsAppleFoundationModels = supportsAppleFoundationModels
        self.osVersion = osVersion
        self.deviceModel = deviceModel
    }

    // Convenience GiB accessors (measured → Double; nil stays nil).
    public var physicalMemoryGB: Double { Double(physicalMemoryBytes) / 1_073_741_824 }
    public var availableMemoryGB: Double? { availableMemoryBytes.map { Double($0) / 1_073_741_824 } }
    public var availableStorageGB: Double? { availableStorageBytes.map { Double($0) / 1_073_741_824 } }
}
