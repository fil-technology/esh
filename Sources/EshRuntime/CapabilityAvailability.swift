import Foundation
import EshCore

// esh 2.4 — §6 capability discovery. Per-capability availability an app can render directly, instead of
// only the coarse backend-readiness in `EshCapabilitySnapshot`. States are honest: a capability is `.ready`
// only when a provider is wired AND anything it needs (a text model) is ready; otherwise the exact reason
// is surfaced so the product shows the correct "needs download / unsupported here / coming later" state.

/// The honest availability of one capability on this device, right now.
public enum CapabilityAvailability: Sendable, Equatable {
    /// A provider is wired and everything it needs is ready — the capability can run now.
    case ready
    /// Wired, but needs a model downloaded first (e.g. a GGUF text model for artifact generation).
    /// `modelID`/`bytes` are filled when a specific recommended model is known.
    case requiresDownload(modelID: String?, bytes: Int64?)
    /// A required model is currently downloading/installing.
    case installing(progress: Double)
    /// A required runtime/engine is present but broken (missing/corrupt dependency, e.g. `soundfile`).
    /// esh can repair it; the app should offer/trigger repair rather than showing a raw error.
    case repairRequired(reason: String)
    /// A prior attempt failed in a way that isn't a clean transient (surfaced from a typed error).
    case failed(reason: String)
    /// Wired, but not ready for a transient reason (e.g. no text backend loaded yet, low memory).
    case temporarilyUnavailable(reason: String)
    /// The underlying tech cannot run on THIS device (e.g. hardware/OS below the floor) though the
    /// platform could otherwise support it.
    case unsupportedOnDevice(reason: String)
    /// This platform cannot provide the capability at all (e.g. a Python/MLX-only generator on iOS).
    case unsupportedOnPlatform
    /// Planned but not yet shipped in this SDK build.
    case comingLater
}

/// A snapshot of per-capability availability. Build it from `EshRuntime.capabilityAvailability()`.
public struct CapabilityAvailabilitySnapshot: Sendable {
    /// Availability keyed by capability. Only capabilities the SDK knows about are present.
    public var entries: [CapabilityID: CapabilityAvailability]
    public init(entries: [CapabilityID: CapabilityAvailability]) { self.entries = entries }

    /// Availability for a capability. Unknown capabilities read as `.comingLater` (honest default: the SDK
    /// makes no claim it can serve something it doesn't model).
    public func state(for capability: CapabilityID) -> CapabilityAvailability {
        entries[capability] ?? .comingLater
    }

    /// True when the capability can run now.
    public func isReady(_ capability: CapabilityID) -> Bool {
        if case .ready = state(for: capability) { return true }
        return false
    }
}

/// A `CapabilityProvider` whose availability depends on live runtime state (installed? repair needed?
/// downloading?) can conform to this so `EshRuntime.capabilityAvailability()` reports its honest state
/// instead of a static `.ready`. The value must be cheap/synchronous — providers cache it and refresh it
/// off the hot path (e.g. after a preflight/execute). Used by the macOS compatibility engines.
public protocol CapabilityAvailabilityReporting: Sendable {
    /// The provider's current availability for one of its capabilities, or `nil` to defer to the default.
    func reportedAvailability(for capability: CapabilityID) -> CapabilityAvailability?
}

/// A reporting provider that can refresh its cached state from a live preflight. Call
/// `EshRuntime.refreshCapabilityAvailability()` before reading discovery to get accurate live states
/// (e.g. after installing an engine, or at app launch).
public protocol CapabilityAvailabilityRefreshing: CapabilityAvailabilityReporting {
    func refreshAvailability() async
}
