import Foundation
import EshCore

enum EnginesCommand {
    static func run(arguments: [String], root: PersistenceRoot) throws {
        let configuration = try OrchestratorConfigurationStore(root: root).load()
        let detector = EngineDetectionService(configuration: configuration)
        guard let subcommand = arguments.first else {
            try printList(detector: detector)
            return
        }

        switch subcommand {
        case "list":
            try printList(detector: detector)
        case "doctor":
            guard let value = arguments.dropFirst().first,
                  let engine = EngineID(argument: value) else {
                throw StoreError.invalidManifest("Usage: esh engines doctor <llama.cpp|mlx|ollama|llamafile|transformers>")
            }
            let result = try detector.detect(engine: engine)
            for line in doctorLines(result: result) {
                print(line)
            }
        default:
            throw StoreError.invalidManifest("Usage: esh engines list | esh engines doctor <engine>")
        }
    }

    static func listLines(results: [EngineDetectionResult]) -> [String] {
        results.map { result in
            [
                padded(result.engine.displayName, width: 12),
                padded(result.installed ? "installed" : "missing", width: 12),
                padded(result.status.rawValue, width: 11),
                padded(result.isOptional ? "optional" : "required", width: 11),
                summary(for: result)
            ].joined()
        }
    }

    static func doctorLines(result: EngineDetectionResult) -> [String] {
        var lines = [
            "Engine: \(result.engine.displayName)",
            "Status: \(result.status.rawValue)",
            "Installed: \(result.installed ? "yes" : "no")",
            "Required: \(result.isOptional ? "no" : "yes")",
            "Platform compatible: \(result.platformCompatible ? "yes" : "no")"
        ]
        if let version = result.version {
            lines.append("Version: \(version)")
        }
        if let binaryPath = result.binaryPath {
            lines.append("Binary: \(binaryPath)")
        }
        if let packagePath = result.packagePath {
            lines.append("Package: \(packagePath)")
        }
        lines.append("Acceleration: \(accelerationLabel(result.acceleration))")
        if !result.formats.isEmpty {
            lines.append("Formats: \(result.formats.map(formatLabel).joined(separator: ", "))")
        }
        if !result.capabilities.isEmpty {
            lines.append("Capabilities: \(result.capabilities.joined(separator: ", "))")
        }
        if !result.limitations.isEmpty {
            lines.append("Limitations:")
            lines.append(contentsOf: result.limitations.map { "  - \($0)" })
        }
        if let suggestedFix = result.suggestedFix {
            lines.append("Suggested fix: \(suggestedFix)")
        }
        return lines
    }

    private static func printList(detector: EngineDetectionService) throws {
        for line in listLines(results: try detector.detectAll()) {
            print(line)
        }
    }

    private static func summary(for result: EngineDetectionResult) -> String {
        var values = result.formats.map(formatLabel)
        if case .available(let label) = result.acceleration {
            values.append(label)
        }
        values.append(contentsOf: result.capabilities)

        var seen: Set<String> = []
        let unique = values.filter { seen.insert($0).inserted }
        return unique.isEmpty ? "-" : unique.joined(separator: ", ")
    }

    private static func accelerationLabel(_ acceleration: EngineAcceleration) -> String {
        switch acceleration {
        case .available(let label):
            return label
        case .unavailable(let reason):
            return "unavailable (\(reason))"
        case .unknown:
            return "unknown"
        }
    }

    private static func formatLabel(_ format: ModelFormat) -> String {
        format.rawValue.uppercased()
    }

    private static func padded(_ value: String, width: Int) -> String {
        if value.count >= width {
            return value + " "
        }
        return value + String(repeating: " ", count: width - value.count)
    }
}
