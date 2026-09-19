import Foundation

// Public, truthful read-model of esh's runtime resource state, for a consumer's "Resources" surface.
// Every field reports only what esh genuinely knows — a measured memory number is never synthesized from
// an estimate, and models esh cannot introspect simply do not appear. Model-viability judgment stays inside
// esh (Model Fit / the resource scheduler); this type is facts, not decisions.

/// Residency of a heavy model/runtime esh is keeping in memory.
public enum ModelResidency: String, Codable, Hashable, Sendable {
    case warm     // resident + ready, not currently serving a request
    case active   // resident + currently serving a request
    case idle     // resident but past its last use (an eviction candidate)
}

/// One resident model/runtime, as esh actually knows it. `measuredMemoryBytes` is populated ONLY when esh
/// has a genuine measurement; `estimatedPeakMemoryBytes` is the provider's declared estimate and is always
/// clearly distinct from a measurement.
public struct ResidentModel: Identifiable, Sendable, Equatable {
    public let id: String                    // provider/model id used for pinning + unload
    public let displayName: String?
    public let modelID: String?              // model family/checkpoint id when the provider advertises one
    public let capability: CapabilityID?     // the primary capability this provider backs
    public let residency: ModelResidency
    public let measuredMemoryBytes: Int64?   // genuine measurement only; nil when esh has not measured
    public let estimatedPeakMemoryBytes: Int64?  // declared estimate; never conflated with `measured`

    public init(id: String, displayName: String? = nil, modelID: String? = nil, capability: CapabilityID? = nil,
                residency: ModelResidency, measuredMemoryBytes: Int64? = nil, estimatedPeakMemoryBytes: Int64? = nil) {
        self.id = id; self.displayName = displayName; self.modelID = modelID; self.capability = capability
        self.residency = residency; self.measuredMemoryBytes = measuredMemoryBytes
        self.estimatedPeakMemoryBytes = estimatedPeakMemoryBytes
    }
}

/// Device resource facts a consumer needs to reason about headroom, distinguishing the system/runtime volume
/// (swap headroom) from the assets/model volume. All optional fields are `nil` when the platform cannot
/// report them honestly.
public struct ResourcePressureSnapshot: Sendable, Equatable {
    public let totalMemoryBytes: Int64
    public let availableMemoryBytes: Int64?
    /// esh's own judgment that memory is under critical pressure (thermal-critical or available memory below
    /// a safe floor). This is the one bit of viability judgment esh exposes; the raw facts are alongside it.
    public let memoryCritical: Bool
    public let systemVolumeFreeBytes: Int64?
    public let assetsVolumeFreeBytes: Int64?

    public init(totalMemoryBytes: Int64, availableMemoryBytes: Int64?, memoryCritical: Bool,
                systemVolumeFreeBytes: Int64?, assetsVolumeFreeBytes: Int64?) {
        self.totalMemoryBytes = totalMemoryBytes; self.availableMemoryBytes = availableMemoryBytes
        self.memoryCritical = memoryCritical
        self.systemVolumeFreeBytes = systemVolumeFreeBytes; self.assetsVolumeFreeBytes = assetsVolumeFreeBytes
    }
}

/// Typed outcomes for an explicit unload request — an active model is never force-unloaded.
public enum UnloadError: Error, LocalizedError, Equatable {
    case unknownModel(String)       // no resident model with this id
    case modelActive(String)        // resident but serving a request; refuse rather than force
    case notUnloadable(String)      // provider does not support unloading

    public var errorDescription: String? {
        switch self {
        case let .unknownModel(id): return "No resident model with id \(id)."
        case let .modelActive(id): return "Model \(id) is serving a request and cannot be unloaded right now."
        case let .notUnloadable(id): return "Model \(id) does not support unloading."
        }
    }
}

public extension CapabilityRegistry {
    /// The heavy models/runtimes esh is currently keeping resident, from providers that report runtime state
    /// (`ResourceStateReporting`). Providers that don't report state, and LLM/text backends whose residency
    /// esh does not track at this layer, are omitted — the snapshot never guesses.
    func residentModels() -> [ResidentModel] {
        let gb = 1_073_741_824.0
        return all.compactMap { provider -> ResidentModel? in
            guard let reporting = provider as? ResourceStateReporting else { return nil }
            let state = reporting.resourceState
            guard state.warm else { return nil }
            let d = provider.descriptor
            let estimated = d.resourceProfile.map { Int64($0.estimatedPeakMemoryGB * gb) }
            return ResidentModel(
                id: d.id, displayName: nil, modelID: d.modelFamily, capability: d.capabilities.first,
                residency: state.active ? .active : .warm,
                measuredMemoryBytes: nil, estimatedPeakMemoryBytes: estimated)
        }
    }

    /// Providers that are unloadable candidates right now (warm/idle, not active). Used by "unload idle".
    func idleUnloadableProviderIDs() -> [String] {
        all.compactMap { provider in
            guard let reporting = provider as? ResourceStateReporting else { return nil }
            let s = reporting.resourceState
            return (s.warm && !s.active) ? provider.descriptor.id : nil
        }
    }
}
