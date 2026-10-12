import Foundation

/// A LIVE, load-time memory-safety gate for heavy local models (brief P0). Distinct from `ModelFitService`,
/// which is a pre-DOWNLOAD fit estimate against TOTAL memory: this judges whether loading a model RIGHT NOW is
/// safe given the live snapshot — available memory + swap headroom (= internal/system-volume free space). Its
/// job is to make a large model (e.g. an 80B at ~22 GB) fail *safely with a reason* when the machine can't host
/// it this moment, instead of driving macOS into an unrecoverable swap hang. It must NEVER require a reboot as a
/// normal prerequisite — it only checks, and the caller rejects.
///
/// Pure + deterministic (reuses `HostResources` + `ResourceFitVerdict`), so it is unit-tested with synthetic
/// hosts. Conservative by construction: a model that comfortably fits available memory always passes, and a
/// trivially small model is never gated — so existing small-model flows are unaffected.
public enum MemorySafetyPreflight: Sendable {
    /// Models below this never gate — avoids a noisy/absent `availableMemoryGB` reading ever blocking a model
    /// that plainly fits on any supported Mac.
    public static let smallModelFloorGB: Double = 4.0
    /// Minimum free space the internal (swap) volume must retain beyond the projected swap deficit, so macOS
    /// keeps room to operate. The pre-reboot near-miss (≈0.3 GB free, swap ~maxed) is exactly what this catches.
    public static let swapDiskFloorGB: Double = 3.0

    public static func evaluate(requiredPeakGB: Double, host: HostResources) -> ResourceFitVerdict {
        guard requiredPeakGB >= smallModelFloorGB else { return .fits }

        let total = host.totalMemoryGB
        if total > 0, requiredPeakGB > total * 0.98 {
            return .gated(reason: String(format: "model needs ~%.0f GB, more than this Mac's %.0f GB of memory",
                                         requiredPeakGB, total),
                          requiredGB: requiredPeakGB, availableGB: total)
        }

        // Effective available memory: measured when known, else a conservative fraction of total (do NOT
        // fabricate danger from an unmeasurable reading — fabricating safety is the only real hazard).
        let avail = host.availableMemoryGB ?? (total * 0.6)

        if host.memoryCritical && requiredPeakGB > total * 0.3 {
            return .gated(reason: "system memory pressure is critical right now — free memory and retry",
                          requiredGB: requiredPeakGB, availableGB: avail)
        }

        // Room to load without meaningful swap → safe.
        if requiredPeakGB <= avail { return .fits }

        let deficit = requiredPeakGB - avail
        // The deficit must be absorbed by swap, which grows on the internal/system volume. If that volume is
        // nearly full, swap cannot grow and the load would thrash/hang → reject (the reboot-prevention guard).
        if let swapHeadroom = host.systemVolumeFreeGB, swapHeadroom < deficit + swapDiskFloorGB {
            return .gated(
                reason: String(format: "needs ~%.0f GB but only ~%.0f GB is free now and the internal disk has ~%.1f GB for swap; close apps or free disk space, then retry (no reboot required)",
                               requiredPeakGB, avail, swapHeadroom),
                requiredGB: requiredPeakGB, availableGB: avail)
        }
        // Even with disk room, a large deficit means heavy sustained swap — unsafe/unusable for interactive use.
        if total > 0, deficit > total * 0.4 {
            return .gated(
                reason: String(format: "would require heavy swapping (~%.0f GB beyond the ~%.0f GB free) and run unusably slowly; free memory and retry",
                               deficit, avail),
                requiredGB: requiredPeakGB, availableGB: avail)
        }
        return .fits
    }
}
