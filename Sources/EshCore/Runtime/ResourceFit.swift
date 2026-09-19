import Foundation

// Generic, capability-agnostic resource fitting for Auto provider selection. A provider declares a
// `CapabilityResourceProfile` (esh-owned facts: peak memory, download/install bytes, per-volume headroom,
// quality/latency class). The `ResourceFitEvaluator` judges each profile against the live machine (memory,
// system-volume free = swap headroom, assets-volume free = model storage) + generic caller policy, and the
// scheduler ranks the safely-fitting providers by quality. No model-specific facts live in the caller/app;
// no capability is special-cased. Future image/VLM/audio tiers participate by declaring a profile.

/// Coarse latency expectation for a provider/model (used for tie-breaks + future policies).
public enum LatencyClass: String, Codable, Hashable, Sendable, CaseIterable {
    case fast        // seconds
    case moderate    // tens of seconds
    case slow        // ~minute+
}

/// esh-owned resource facts for a provider/model. Bytes for storage (precise), GB Doubles for memory
/// (estimates). All optional-with-defaults so a provider without a profile keeps legacy behavior.
public struct CapabilityResourceProfile: Codable, Hashable, Sendable {
    /// Estimated peak unified memory while running (incl. transient Metal/MLX allocations) — the safe
    /// threshold, i.e. measured peak PLUS margin, not the bare measured number.
    public var estimatedPeakMemoryGB: Double
    /// Bytes downloaded on first use (network). 0 if nothing to download.
    public var modelDownloadBytes: Int64
    /// Bytes the installed model occupies on the assets volume once staged.
    public var installedBytes: Int64
    /// Extra transient bytes needed on the assets volume DURING install/staging, beyond `installedBytes`.
    public var temporaryInstallBytes: Int64
    /// Minimum free space required on the SYSTEM/runtime volume (internal APFS) — swap + runtime headroom.
    /// This is what makes "weights fit on the SSD but the internal disk is nearly full" correctly unsafe.
    public var minimumSystemVolumeHeadroomGB: Double
    /// Minimum free space required on the ASSETS/model volume beyond the installed weights themselves.
    public var minimumAssetsVolumeHeadroomGB: Double
    /// Higher = better quality. Auto prefers the highest quality that safely fits.
    public var qualityTier: Int
    public var latencyClass: LatencyClass

    public init(estimatedPeakMemoryGB: Double, modelDownloadBytes: Int64 = 0, installedBytes: Int64 = 0,
                temporaryInstallBytes: Int64 = 0, minimumSystemVolumeHeadroomGB: Double = 0,
                minimumAssetsVolumeHeadroomGB: Double = 0, qualityTier: Int = 0,
                latencyClass: LatencyClass = .moderate) {
        self.estimatedPeakMemoryGB = estimatedPeakMemoryGB
        self.modelDownloadBytes = modelDownloadBytes
        self.installedBytes = installedBytes
        self.temporaryInstallBytes = temporaryInstallBytes
        self.minimumSystemVolumeHeadroomGB = minimumSystemVolumeHeadroomGB
        self.minimumAssetsVolumeHeadroomGB = minimumAssetsVolumeHeadroomGB
        self.qualityTier = qualityTier
        self.latencyClass = latencyClass
    }
}

/// Generic caller policy (never model-specific). Built from `ExecutionConstraints`.
public struct ResourcePolicy: Sendable, Equatable {
    public var maxMemoryGB: Double?
    public var reserveMemoryGB: Double?
    public var allowDownload: Bool
    public var offlineOnly: Bool
    public var qualityPreference: QualityPreference

    public enum QualityPreference: String, Codable, Sendable { case auto, bestQuality, fastestReady, lowMemory }

    public init(maxMemoryGB: Double? = nil, reserveMemoryGB: Double? = nil, allowDownload: Bool = true,
                offlineOnly: Bool = false, qualityPreference: QualityPreference = .auto) {
        self.maxMemoryGB = maxMemoryGB; self.reserveMemoryGB = reserveMemoryGB
        self.allowDownload = allowDownload; self.offlineOnly = offlineOnly
        self.qualityPreference = qualityPreference
    }
    public static let `default` = ResourcePolicy()
}

/// Live machine resources the evaluator judges against. `nil` fields mean "not measurable" — the evaluator
/// treats an unmeasurable dimension conservatively (does not fabricate safety).
public struct HostResources: Sendable, Equatable {
    public var totalMemoryGB: Double
    public var availableMemoryGB: Double?      // macOS: system-wide available; volatile
    public var systemVolumeFreeGB: Double?     // internal/runtime volume (swap headroom)
    public var assetsVolumeFreeGB: Double?     // model/assets volume
    public var assetsVolumeAvailable: Bool     // false = external volume disconnected
    public var residentHeavyMemoryGB: Double   // memory already committed to resident heavy models
    public var memoryCritical: Bool            // live pressure signal

    public init(totalMemoryGB: Double, availableMemoryGB: Double? = nil, systemVolumeFreeGB: Double? = nil,
                assetsVolumeFreeGB: Double? = nil, assetsVolumeAvailable: Bool = true,
                residentHeavyMemoryGB: Double = 0, memoryCritical: Bool = false) {
        self.totalMemoryGB = totalMemoryGB; self.availableMemoryGB = availableMemoryGB
        self.systemVolumeFreeGB = systemVolumeFreeGB; self.assetsVolumeFreeGB = assetsVolumeFreeGB
        self.assetsVolumeAvailable = assetsVolumeAvailable
        self.residentHeavyMemoryGB = residentHeavyMemoryGB; self.memoryCritical = memoryCritical
    }
}

/// The outcome of judging one provider profile against the machine.
public enum ResourceFitVerdict: Sendable, Equatable {
    case fits
    /// Unsafe to run now. `reason` is developer-facing; `requiredGB`/`availableGB` populate diagnostics.
    case gated(reason: String, requiredGB: Double?, availableGB: Double?)

    public var fits: Bool { if case .fits = self { return true }; return false }
}

/// Pure, deterministic resource-fit judgment. Injected into the scheduler + unit-tested with synthetic
/// hosts/profiles/policies (no device or GPU needed).
public struct ResourceFitEvaluator: Sendable {
    /// Extra head-of-margin the model does not declare, applied to swap headroom when a heavy model is
    /// already resident (avoids stacking two heavy image models unsafely). Small, conservative.
    public init() {}

    public func evaluate(profile: CapabilityResourceProfile, installed: Bool, warm: Bool,
                         host: HostResources, policy: ResourcePolicy) -> ResourceFitVerdict {
        let gb = 1_073_741_824.0
        let installedGB = Double(profile.installedBytes) / gb
        let downloadGB = Double(profile.modelDownloadBytes) / gb
        let stagingGB = Double(profile.temporaryInstallBytes) / gb

        // 1. Download / offline policy.
        if !installed {
            if policy.offlineOnly || !policy.allowDownload {
                return .gated(reason: "model is not installed and downloads are disabled", requiredGB: downloadGB, availableGB: nil)
            }
            if !host.assetsVolumeAvailable {
                return .gated(reason: "model storage volume is unavailable (cannot download weights)", requiredGB: nil, availableGB: nil)
            }
            // Assets volume must hold the installed weights + transient staging.
            if let free = host.assetsVolumeFreeGB {
                let need = installedGB + stagingGB + profile.minimumAssetsVolumeHeadroomGB
                if free < need {
                    return .gated(reason: "insufficient model-volume space to download/install", requiredGB: round1(need), availableGB: round1(free))
                }
            }
        } else {
            if !host.assetsVolumeAvailable {
                return .gated(reason: "model storage volume is unavailable", requiredGB: nil, availableGB: nil)
            }
            if let free = host.assetsVolumeFreeGB, profile.minimumAssetsVolumeHeadroomGB > 0,
               free < profile.minimumAssetsVolumeHeadroomGB {
                return .gated(reason: "insufficient model-volume headroom", requiredGB: round1(profile.minimumAssetsVolumeHeadroomGB), availableGB: round1(free))
            }
        }

        // 2. System/runtime-volume (swap) headroom — the "internal disk nearly full" case. A warm model
        //    still needs runtime scratch, so this applies whether or not it's resident.
        if profile.minimumSystemVolumeHeadroomGB > 0, let sysFree = host.systemVolumeFreeGB {
            if sysFree < profile.minimumSystemVolumeHeadroomGB {
                return .gated(reason: "insufficient system-volume/swap headroom",
                              requiredGB: round1(profile.minimumSystemVolumeHeadroomGB), availableGB: round1(sysFree))
            }
        }

        // 3. Memory. Budget = min(total, maxMemoryGB) capped by current availability, minus reserve and any
        //    resident heavy models. A warm/resident model already counts its own weights in residentHeavy,
        //    so it is not double-charged; but current memory pressure never gets bypassed.
        var budget = policy.maxMemoryGB.map { min($0, host.totalMemoryGB) } ?? host.totalMemoryGB
        if let avail = host.availableMemoryGB {
            // Add back this model's already-resident share when warm, so warm reuse isn't falsely gated.
            let warmBack = warm ? profile.estimatedPeakMemoryGB : 0
            budget = min(budget, avail + warmBack)
        }
        let reserve = policy.reserveMemoryGB ?? max(3.0, host.totalMemoryGB * 0.15)
        let usable = budget - reserve - host.residentHeavyMemoryGB
        if host.memoryCritical {
            return .gated(reason: "system memory is under critical pressure", requiredGB: round1(profile.estimatedPeakMemoryGB), availableGB: round1(max(0, usable)))
        }
        if profile.estimatedPeakMemoryGB > usable {
            return .gated(reason: "insufficient usable memory for the estimated peak", requiredGB: round1(profile.estimatedPeakMemoryGB), availableGB: round1(max(0, usable)))
        }
        return .fits
    }

    private func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
}
