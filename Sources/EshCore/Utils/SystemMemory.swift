import Foundation
import Darwin

public struct SystemMemorySnapshot: Sendable {
    public let totalBytes: Int64
    public let availableBytes: Int64

    public init(totalBytes: Int64, availableBytes: Int64) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }
}

/// A live snapshot of the machine's shared resources for the Engine inspector's usage meters. RAM is always
/// present; `gpuUtilizationPercent` is nil when it can't be read (shown as "—", never faked).
public struct SystemResourcesSnapshot: Codable, Sendable {
    public let totalMemoryBytes: Int64
    public let availableMemoryBytes: Int64
    public let usedMemoryBytes: Int64
    public let gpuUtilizationPercent: Double?

    public static func current() -> SystemResourcesSnapshot {
        let mem = SystemMemory.snapshot()
        let total = mem?.totalBytes ?? Int64(ProcessInfo.processInfo.physicalMemory)
        let available = mem?.availableBytes ?? 0
        return SystemResourcesSnapshot(
            totalMemoryBytes: total,
            availableMemoryBytes: available,
            usedMemoryBytes: max(0, total - available),
            gpuUtilizationPercent: SystemGPU.utilizationPercent())
    }
}

/// Preflight for a heavy image run: decide whether there's enough RAM to even START, so we refuse fast with
/// an actionable message instead of loading a multi-GB model and having it killed mid-run. Called AFTER the
/// warm-model reclaim, so it sees the true post-reclaim headroom.
public enum HeavyTaskMemory {
    /// nil when there's enough headroom (or memory can't be measured — never block on a probe failure);
    /// otherwise a human-readable reason naming the shortfall and the biggest thing to close.
    public static func insufficientMemoryMessage(neededGB: Double, label: String) -> String? {
        guard let snap = SystemMemory.snapshot() else { return nil }
        let availableGB = Double(snap.availableBytes) / 1_073_741_824.0
        if availableGB >= neededGB { return nil }
        let free = String(format: "%.1f", availableGB)
        let need = String(format: "%.0f", neededGB)
        var msg = "Not enough free memory to start \(label): \(free) GB available, about \(need) GB needed. "
        if let hog = SystemProcesses.topConsumer() {
            msg += "The biggest memory user right now is \(hog.name) (\(String(format: "%.1f", hog.gigabytes)) GB). Close apps you don't need, then try again."
        } else {
            msg += "Close some apps to free memory, then try again."
        }
        return msg
    }
}

public enum SystemMemory {
    public static func snapshot() -> SystemMemorySnapshot? {
        let total = Int64(ProcessInfo.processInfo.physicalMemory)

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else {
            return nil
        }

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return nil
        }

        let availablePages = Int64(stats.free_count) + Int64(stats.inactive_count) + Int64(stats.speculative_count)
        let available = availablePages * Int64(pageSize)
        return SystemMemorySnapshot(totalBytes: total, availableBytes: available)
    }
}
