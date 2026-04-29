import Foundation
import EshCore

enum DoctorCommand {
    static func run() throws {
        for line in try outputLines() {
            print(line)
        }
    }

    static func outputLines() throws -> [String] {
        let root = PersistenceRoot.default()
        let configuration = try OrchestratorConfigurationStore(root: root).load()
        let hostSystem = EngineHostSystem.current()
        let hostProfile = HostMachineProfileService().currentProfile()
        let engines = try EngineDetectionService(
            configuration: configuration,
            hostSystem: hostSystem
        ).detectAll()
        let storage = SystemStorage.snapshot(at: storageProbeURL(root: root))

        var lines: [String] = [
            "System",
            "  macOS: \(hostSystem.operatingSystem)",
            "  Architecture: \(hostSystem.architecture)",
            "  Apple Silicon: \(hostSystem.isAppleSilicon ? "yes" : "no")"
        ]

        if let totalMemoryGB = hostProfile.totalMemoryGB {
            lines.append("  Memory: \(String(format: "%.1f GB", totalMemoryGB))")
        }
        if let availableMemoryGB = hostProfile.availableMemoryGB {
            lines.append("  Available memory: \(String(format: "%.1f GB", availableMemoryGB))")
        }
        if let safeBudgetGB = hostProfile.safeBudgetGB {
            lines.append("  Safe model budget: \(String(format: "%.1f GB", safeBudgetGB))")
        }

        lines.append("")
        lines.append("Engines")
        for engine in engines {
            let status = engine.status.rawValue
            let optional = engine.isOptional ? "optional" : "required"
            lines.append("  \(engine.engine.displayName): \(status), \(optional), \(engineSummary(engine))")
        }

        lines.append("")
        lines.append("Models")
        lines.append("  Persistence root: \(root.rootURL.path)")
        lines.append("  Config: \(OrchestratorConfigurationStore(root: root).configURL.path)")
        lines.append("  Model directory: \(root.modelsURL.path)")
        if let storage {
            lines.append("  Disk available: \(ByteFormatting.string(for: storage.availableBytes))")
        }

        for warning in hostProfile.warnings {
            lines.append("  Warning: \(warning)")
        }

        let required = engines.filter { !$0.isOptional }
        let readyRequired = required.filter { $0.status == .ready }
        lines.append("")
        lines.append("Status: \(readyRequired.isEmpty ? "attention" : "ready")")
        return lines
    }

    private static func engineSummary(_ result: EngineDetectionResult) -> String {
        var values = result.formats.map { $0.rawValue.uppercased() }
        switch result.acceleration {
        case .available(let label):
            values.append(label)
        case .unavailable(let reason):
            values.append("no acceleration: \(reason)")
        case .unknown:
            break
        }
        if let version = result.version {
            values.append(version)
        }
        if values.isEmpty {
            values.append(result.suggestedFix ?? "-")
        }
        return values.joined(separator: ", ")
    }

    private static func storageProbeURL(root: PersistenceRoot) -> URL {
        for candidate in [root.modelsURL, root.rootURL, FileManager.default.homeDirectoryForCurrentUser]
        where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
