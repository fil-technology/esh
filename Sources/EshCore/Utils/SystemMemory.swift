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
