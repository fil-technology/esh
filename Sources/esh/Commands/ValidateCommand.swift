import Foundation
import EshCore

enum ValidateCommand {
    static func run(arguments: [String], root: PersistenceRoot) throws {
        let jsonOutput = arguments.contains("--json")
        let requestedEngine = try requestedEngine(from: arguments)
        let positional = CommandSupport.positionalArguments(in: arguments, knownFlags: ["--engine"])
            .filter { !$0.hasPrefix("--") }
        guard let identifier = positional.first else {
            throw StoreError.invalidManifest("Usage: esh validate <model-id-or-repo> [--engine llama.cpp|mlx] [--json]")
        }

        let modelStore = FileModelStore(root: root)
        let configuration = try OrchestratorConfigurationStore(root: root).load()
        let install = try CommandSupport.resolveInstall(identifier: identifier, modelStore: modelStore)
        let report = try ModelValidationService().validate(
            install: install,
            requestedEngine: requestedEngine,
            hostSystem: .current(),
            engines: try EngineDetectionService(configuration: configuration).detectAll()
        )

        if jsonOutput {
            let data = try JSONCoding.encoder.encode(report)
            print(String(decoding: data, as: UTF8.self))
            return
        }

        for line in outputLines(report: report) {
            print(line)
        }
    }

    static func outputLines(report: ModelValidationReport) -> [String] {
        var lines = [
            "Model: \(report.modelID)",
            "Name: \(report.displayName)",
            "Path: \(report.localPath)",
            "Format: \(report.detectedFormat.rawValue.uppercased())",
            "Size: \(ByteFormatting.string(for: report.sizeBytes))"
        ]
        if !report.foundFiles.isEmpty {
            let sample = report.foundFiles.prefix(8).joined(separator: ", ")
            let suffix = report.foundFiles.count > 8 ? " ..." : ""
            lines.append("Found files: \(sample)\(suffix)")
        }
        lines.append("Compatible engines: \(engineList(report.compatibleEngines))")
        if let selectedEngine = report.selectedEngine {
            lines.append("Selected engine: \(selectedEngine.displayName)")
        } else {
            lines.append("Selected engine: none")
        }
        if let selectedBackend = report.selectedBackend {
            lines.append("Backend: \(selectedBackend.rawValue)")
        }
        if let selectionExplanation = report.selectionExplanation {
            lines.append("Decision: \(selectionExplanation)")
        }
        if !report.missingDependencies.isEmpty {
            lines.append("Missing dependencies: \(report.missingDependencies.joined(separator: ", "))")
        }
        if !report.suggestedFixes.isEmpty {
            lines.append("Suggested fixes:")
            lines.append(contentsOf: report.suggestedFixes.map { "  - \($0)" })
        }
        if !report.warnings.isEmpty {
            lines.append("Warnings:")
            lines.append(contentsOf: report.warnings.map { "  - \($0)" })
        }
        return lines
    }

    private static func requestedEngine(from arguments: [String]) throws -> EngineID? {
        guard let value = CommandSupport.optionalValue(flag: "--engine", in: arguments) else {
            return nil
        }
        guard let engine = EngineID(argument: value) else {
            throw StoreError.invalidManifest("Unknown engine \(value). Use llama.cpp or mlx.")
        }
        return engine
    }

    private static func engineList(_ engines: [EngineID]) -> String {
        engines.isEmpty ? "none" : engines.map(\.displayName).joined(separator: ", ")
    }
}
