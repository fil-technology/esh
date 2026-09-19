import Foundation

// Resource-aware provider selection for a capability that has several providers (tiers) of differing cost.
// Generic + capability-agnostic: it ranks providers that declare a `CapabilityResourceProfile` by quality,
// keeps only those that safely fit the live machine (memory + per-volume disk + swap headroom + policy),
// and either selects the best or returns a typed resource gate. Providers without a profile fall back to
// the legacy native-first behavior untouched. See ResourceFit.swift for the fit judgment.

/// Live install/warm state for one provider, supplied by the runtime wiring.
public struct ProviderRuntimeState: Sendable, Equatable {
    public var installed: Bool   // weights present on disk (no download needed)
    public var warm: Bool        // pipeline already resident in memory
    public var active: Bool      // currently serving a request (never force-unload)
    public init(installed: Bool = false, warm: Bool = false, active: Bool = false) {
        self.installed = installed; self.warm = warm; self.active = active
    }
}

/// A provider that can report its install/warm state synchronously to the scheduler. Backed by
/// `ProviderStateBox` so an actor-based engine can publish state without the scheduler awaiting it.
public protocol ResourceStateReporting: Sendable {
    var resourceState: ProviderRuntimeState { get }
}

/// Thread-safe, lock-guarded publisher of a provider's install/warm state. The engine writes (on stage /
/// load / unload); the provider reads synchronously during selection.
public final class ProviderStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _state: ProviderRuntimeState
    public init(_ initial: ProviderRuntimeState = .init()) { _state = initial }
    public var state: ProviderRuntimeState {
        lock.lock(); defer { lock.unlock() }; return _state
    }
    public func setInstalled(_ v: Bool) { lock.lock(); _state.installed = v; lock.unlock() }
    public func setWarm(_ v: Bool) { lock.lock(); _state.warm = v; lock.unlock() }
    public func setActive(_ v: Bool) { lock.lock(); _state.active = v; lock.unlock() }
}

/// One provider offered to the scheduler, reduced to what selection needs.
public struct ResourceCandidate: Sendable {
    public var providerID: String
    public var profile: CapabilityResourceProfile?
    public var state: ProviderRuntimeState
    public init(providerID: String, profile: CapabilityResourceProfile?, state: ProviderRuntimeState = .init()) {
        self.providerID = providerID; self.profile = profile; self.state = state
    }
}

/// A typed "supported but not safe to run now" result. For an explicit pin this is returned instead of
/// substituting another provider; for Auto it means nothing safely fits.
public struct CapabilityResourceGate: Sendable, Equatable {
    public var capability: String
    public var providerID: String?   // the gated pin (explicit), or nil (Auto: nothing fit)
    public var explicit: Bool
    public var reason: String
    public var requiredGB: Double?
    public var availableGB: Double?

    public var message: String {
        var m = providerID.map { "\($0) is temporarily unavailable: \(reason)" } ?? "no provider can safely run \(capability) right now: \(reason)"
        if let r = requiredGB, let a = availableGB { m += " (needs ~\(r) GB, ~\(a) GB available)" }
        return m
    }
}

/// Per-candidate record of what the scheduler decided, for explainable routing.
public struct ResourceSelectionDiagnostics: Sendable, Equatable {
    public struct Considered: Sendable, Equatable {
        public var providerID: String
        public var qualityTier: Int?
        public var verdict: String     // "fits" | gate reason | "no profile (legacy)"
        public var warm: Bool
        public var installed: Bool
    }
    public var chosenProviderID: String?
    public var reason: String
    public var considered: [Considered]
}

public enum ResourceSelectionOutcome: Sendable {
    /// No profiled providers among the candidates — use the legacy `.first` provider.
    case passthrough(reason: String)
    case selected(providerID: String, diagnostics: ResourceSelectionDiagnostics)
    case gated(CapabilityResourceGate, diagnostics: ResourceSelectionDiagnostics)
}

/// Pure, deterministic resource-aware selection. Injected with a `ResourceFitEvaluator`; unit-tested with
/// synthetic hosts/candidates. No IO, no device access.
public struct ResourceScheduler: Sendable {
    private let evaluator: ResourceFitEvaluator
    public init(evaluator: ResourceFitEvaluator = ResourceFitEvaluator()) { self.evaluator = evaluator }

    /// - Parameters:
    ///   - explicit: true when the request pinned a model (candidates are already filtered to the pin).
    ///   - candidates: capability candidates in native-first order (the registry's order).
    public func select(capability: String, explicit: Bool, candidates: [ResourceCandidate],
                       host: HostResources, policy: ResourcePolicy) -> ResourceSelectionOutcome {
        let profiled = candidates.filter { $0.profile != nil }
        guard !profiled.isEmpty else {
            return .passthrough(reason: "no provider declares a resource profile; legacy selection")
        }

        // Evaluate every candidate once (for diagnostics + fit).
        var considered: [ResourceSelectionDiagnostics.Considered] = []
        var verdicts: [String: ResourceFitVerdict] = [:]
        for c in candidates {
            guard let p = c.profile else {
                considered.append(.init(providerID: c.providerID, qualityTier: nil,
                                        verdict: "no profile (legacy)", warm: c.state.warm, installed: c.state.installed))
                continue
            }
            let v = evaluator.evaluate(profile: p, installed: c.state.installed, warm: c.state.warm, host: host, policy: policy)
            verdicts[c.providerID] = v
            considered.append(.init(providerID: c.providerID, qualityTier: p.qualityTier,
                                    verdict: v.fits ? "fits" : gateReason(v), warm: c.state.warm, installed: c.state.installed))
        }

        // Explicit pin: honor-or-gate, never substitute.
        if explicit {
            guard let pinned = candidates.first else {
                return .passthrough(reason: "no candidate for the pinned model")
            }
            guard let p = pinned.profile, let v = verdicts[pinned.providerID] else {
                return .passthrough(reason: "pinned provider has no resource profile; legacy selection")
            }
            if v.fits {
                var d = ResourceSelectionDiagnostics(chosenProviderID: pinned.providerID,
                    reason: "explicit pin \(pinned.providerID) fits (quality tier \(p.qualityTier))", considered: considered)
                d.chosenProviderID = pinned.providerID
                return .selected(providerID: pinned.providerID, diagnostics: d)
            }
            let gate = makeGate(capability: capability, providerID: pinned.providerID, explicit: true, verdict: v)
            let d = ResourceSelectionDiagnostics(chosenProviderID: nil,
                reason: "explicit pin \(pinned.providerID) is resource-gated (no substitution): \(gate.reason)", considered: considered)
            return .gated(gate, diagnostics: d)
        }

        // Auto: rank the profiled providers that fit, by policy; fall back or gate.
        let fitting = profiled.filter { verdicts[$0.providerID]?.fits == true }
        if fitting.isEmpty {
            // Prefer a legacy (unprofiled) provider if one exists, rather than failing.
            if candidates.contains(where: { $0.profile == nil }) {
                return .passthrough(reason: "no profiled provider fits the current machine; using legacy provider")
            }
            // Gate with the highest-quality provider's reason (the one the user most likely wanted).
            let best = profiled.max { ($0.profile!.qualityTier) < ($1.profile!.qualityTier) }!
            let gate = makeGate(capability: capability, providerID: nil, explicit: false,
                                verdict: verdicts[best.providerID] ?? .gated(reason: "does not fit", requiredGB: nil, availableGB: nil))
            let d = ResourceSelectionDiagnostics(chosenProviderID: nil,
                reason: "Auto: no provider safely fits; \(gate.reason)", considered: considered)
            return .gated(gate, diagnostics: d)
        }
        let chosen = rank(fitting, policy: policy)
        let p = chosen.profile!
        let reason = "Auto: \(chosen.providerID) — \(rankExplanation(policy: policy)) (quality tier \(p.qualityTier), "
            + "\(chosen.state.warm ? "warm" : chosen.state.installed ? "installed" : "will download"))"
        let d = ResourceSelectionDiagnostics(chosenProviderID: chosen.providerID, reason: reason, considered: considered)
        return .selected(providerID: chosen.providerID, diagnostics: d)
    }

    // Ranking among fitting providers. Quality-first for auto/bestQuality; warm/installed only break ties
    // within the same tier (hysteresis — prevents flapping between equal-quality tiers). Other preferences
    // reorder the primary key but keep the same stable tie-breaks.
    private func rank(_ fitting: [ResourceCandidate], policy: ResourcePolicy) -> ResourceCandidate {
        func readiness(_ c: ResourceCandidate) -> Int { c.state.warm ? 2 : (c.state.installed ? 1 : 0) }
        func latencyRank(_ c: ResourceCandidate) -> Int {   // fast=0 best
            switch c.profile!.latencyClass { case .fast: return 0; case .moderate: return 1; case .slow: return 2 }
        }
        let sorted: [ResourceCandidate]
        switch policy.qualityPreference {
        case .auto, .bestQuality:
            sorted = fitting.sorted { a, b in
                let (pa, pb) = (a.profile!, b.profile!)
                if pa.qualityTier != pb.qualityTier { return pa.qualityTier > pb.qualityTier }
                if readiness(a) != readiness(b) { return readiness(a) > readiness(b) }
                return latencyRank(a) < latencyRank(b)
            }
        case .fastestReady:
            sorted = fitting.sorted { a, b in
                if readiness(a) != readiness(b) { return readiness(a) > readiness(b) }
                if latencyRank(a) != latencyRank(b) { return latencyRank(a) < latencyRank(b) }
                return a.profile!.qualityTier > b.profile!.qualityTier
            }
        case .lowMemory:
            sorted = fitting.sorted { a, b in
                let (ma, mb) = (a.profile!.estimatedPeakMemoryGB, b.profile!.estimatedPeakMemoryGB)
                if ma != mb { return ma < mb }
                return a.profile!.qualityTier > b.profile!.qualityTier
            }
        }
        return sorted.first!
    }

    private func rankExplanation(policy: ResourcePolicy) -> String {
        switch policy.qualityPreference {
        case .auto, .bestQuality: return "highest-quality tier that safely fits"
        case .fastestReady: return "fastest already-ready tier that fits"
        case .lowMemory: return "lowest-memory tier that fits"
        }
    }

    private func gateReason(_ v: ResourceFitVerdict) -> String {
        if case let .gated(reason, _, _) = v { return reason }
        return "fits"
    }

    private func makeGate(capability: String, providerID: String?, explicit: Bool, verdict: ResourceFitVerdict) -> CapabilityResourceGate {
        if case let .gated(reason, req, avail) = verdict {
            return CapabilityResourceGate(capability: capability, providerID: providerID, explicit: explicit,
                                          reason: reason, requiredGB: req, availableGB: avail)
        }
        return CapabilityResourceGate(capability: capability, providerID: providerID, explicit: explicit,
                                      reason: "does not fit", requiredGB: nil, availableGB: nil)
    }
}

/// Assembles a live `HostResources` from esh's existing detection services — the ONE place that reads real
/// device state for scheduling. Distinguishes the system/runtime volume (internal, = swap headroom) from
/// the assets/model volume, using the same primitives as Model Fit + storage reporting.
public enum HostResourceProbe {
    public static func snapshot(root: PersistenceRoot,
                                deviceProfile: DeviceProfileProviding = SystemDeviceProfileProvider(),
                                storage: StorageService = StorageService()) -> HostResources {
        let gb = 1_073_741_824.0
        let p = deviceProfile.currentProfile()
        let availability = storage.availability(root: root)
        // System/runtime volume = the internal state root (where swap lives); assets volume = model store.
        let systemFree = SystemStorage.snapshot(at: root.stateRootURL).map { Double($0.availableBytes) / gb }
        let assetsFree: Double?
        switch availability {
        case let .internalRoot(freeBytes), let .available(freeBytes):
            assetsFree = freeBytes.map { Double($0) / gb }
        case .unavailable:
            assetsFree = nil
        }
        return HostResources(
            totalMemoryGB: p.physicalMemoryGB,
            availableMemoryGB: p.availableMemoryGB,
            systemVolumeFreeGB: systemFree,
            assetsVolumeFreeGB: assetsFree,
            assetsVolumeAvailable: availability.isUsable,
            residentHeavyMemoryGB: 0,
            memoryCritical: p.thermalState == .critical)
    }
}
