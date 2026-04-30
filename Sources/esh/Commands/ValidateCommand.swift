import Foundation
import EshCore

enum ValidateCommand {
    static func run(arguments: [String], root: PersistenceRoot) throws {
        for line in try outputLines(arguments: arguments, root: root) {
            print(line)
        }
    }

    static func outputLines(
        arguments: [String],
        root: PersistenceRoot,
        service: LocalModelValidationService? = nil
    ) throws -> [String] {
        let jsonOutput = arguments.contains("--json")
        let engineValue = CommandSupport.optionalValue(flag: "--engine", in: arguments) ?? "auto"
        let enginePreference = try ModelValidationEnginePreference(cliValue: engineValue)
        let positional = CommandSupport.positionalArguments(in: arguments, knownFlags: ["--engine"])
            .filter { !$0.hasPrefix("--") }
        guard let model = positional.first else {
            throw StoreError.invalidManifest("Usage: esh validate <model-path-or-installed-id> [--engine llama.cpp|mlx] [--json]")
        }

        let modelPath = try resolveModelPath(model, root: root)
        let report = try (service ?? LocalModelValidationService(
            engineService: EngineOrchestratorService(root: root)
        )).validate(modelPath: modelPath, enginePreference: enginePreference)

        if jsonOutput {
            let data = try JSONCoding.encoder.encode(report)
            return [String(decoding: data, as: UTF8.self)]
        }

        return render(report)
    }

    static func render(_ report: ModelValidationReport) -> [String] {
        var lines = [
            "model: \(report.modelPath)",
            "format: \(report.format.rawValue)",
            "compatible_engines: \(report.compatibleEngines.map(\.rawValue).joined(separator: ", "))",
            "ready_engine: \(report.readyEngine?.rawValue ?? "-")"
        ]
        if !report.engineStatuses.isEmpty {
            lines.append("engines:")
            for status in report.engineStatuses {
                lines.append("- \(status.id.rawValue): \(status.ready ? "ready" : "not_ready")")
                if let path = status.executablePath {
                    lines.append("  path: \(path)")
                }
            }
        }
        if !report.notes.isEmpty {
            lines.append("notes:")
            lines += report.notes.map { "- \($0)" }
        }
        if !report.warnings.isEmpty {
            lines.append("warnings:")
            lines += report.warnings.map { "- \($0)" }
        }
        if !report.suggestedFixes.isEmpty {
            lines.append("suggested_fixes:")
            lines += report.suggestedFixes.map { "- \($0)" }
        }
        return lines
    }

    private static func resolveModelPath(_ value: String, root: PersistenceRoot) throws -> String {
        let expanded = expandedURL(value)
        if FileManager.default.fileExists(atPath: expanded.path) {
            return expanded.path
        }

        let modelStore = FileModelStore(root: root)
        if let install = try? CommandSupport.resolveInstall(identifier: value, modelStore: modelStore) {
            return install.installPath
        }

        throw StoreError.notFound("Model path or installed id \(value) was not found.")
    }

    private static func expandedURL(_ path: String) -> URL {
        if path == "~" {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
    }
}
