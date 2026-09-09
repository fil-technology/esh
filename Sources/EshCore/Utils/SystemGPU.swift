import Foundation
import IOKit

// Best-effort GPU utilization for Apple Silicon (and Intel) Macs, read from the IOAccelerator registry's
// `PerformanceStatistics` — the same source Activity Monitor uses. No elevated privileges required (unlike
// `powermetrics`). Returns nil when the value can't be read, so callers show "—" honestly rather than a fake 0.
public enum SystemGPU {
    /// Current GPU device utilization as a percentage (0–100), or nil if unavailable.
    public static func utilizationPercent() -> Double? {
        let matching = IOServiceMatching("IOAccelerator")
        var iterator: io_iterator_t = 0
        // kIOMainPortDefault (0) works on macOS 12+; passing 0 is the documented "default port" value.
        guard IOServiceGetMatchingServices(mach_port_t(MACH_PORT_NULL), matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var best: Double?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = unmanaged?.takeRetainedValue() as? [String: Any],
                  let perf = props["PerformanceStatistics"] as? [String: Any] else { continue }
            // Key naming varies by GPU/driver — accept the common variants.
            let value = (perf["Device Utilization %"] as? NSNumber)?.doubleValue
                ?? (perf["GPU Activity(%)"] as? NSNumber)?.doubleValue
                ?? (perf["Renderer Utilization %"] as? NSNumber)?.doubleValue
            if let value {
                // Prefer the highest reported (integrated + discrete both enumerate; the active one is higher).
                best = max(best ?? 0, value)
            }
        }
        return best
    }
}
