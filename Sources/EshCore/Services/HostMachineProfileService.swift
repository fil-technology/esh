import Foundation
import Darwin

public struct HostMachineProfileService: Sendable {
    public init() {}

    public func currentProfile() -> HostMachineProfile {
        var warnings: [String] = []
        let machineModel = sysctlString(named: "hw.model")
        let chipDescription = sysctlString(named: "machdep.cpu.brand_string")
            ?? (sysctlInt(named: "hw.optional.arm64") == 1 ? "Apple Silicon" : nil)

        guard let snapshot = SystemMemory.snapshot() else {
            warnings.append("Could not determine system memory automatically.")
            return HostMachineProfile(
                machineModel: machineModel,
                chipDescription: chipDescription,
                warnings: warnings
            )
        }

        let totalGB = gibibytes(snapshot.totalBytes)
        let availableGB = gibibytes(snapshot.availableBytes)
        let reserveGB = max(4.0, totalGB * 0.2)
        let availabilityAdjustedGB = max(0, availableGB - max(2.0, reserveGB * 0.5))
        let safeBudgetGB = max(0, min(totalGB - reserveGB, availabilityAdjustedGB))

        if availableGB < reserveGB {
            warnings.append("Current free memory is already under the usual safety margin.")
        }

        return HostMachineProfile(
            machineModel: machineModel,
            chipDescription: chipDescription,
            totalMemoryGB: totalGB,
            availableMemoryGB: availableGB,
            safeBudgetGB: safeBudgetGB,
            warnings: warnings
        )
    }

    private func gibibytes(_ bytes: Int64) -> Double {
        Double(bytes) / 1_073_741_824
    }

    private func sysctlString(named name: String) -> String? {
        var size: size_t = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else {
            return nil
        }

        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            return nil
        }
        let truncated = value.prefix { $0 != 0 }
        return String(decoding: truncated.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func sysctlInt(named name: String) -> Int32? {
        var value = Int32(0)
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            return nil
        }
        return value
    }
}
