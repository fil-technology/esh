import Foundation
import EshCore

enum EnginesCommand {
    static func run(arguments: [String], root: PersistenceRoot) throws {
        for line in try outputLines(arguments: arguments, root: root) {
            print(line)
        }
    }

    static func outputLines(
        arguments: [String],
        root: PersistenceRoot,
        service: EngineOrchestratorService? = nil
    ) throws -> [String] {
        let service = service ?? EngineOrchestratorService(root: root)
        let subcommand = arguments.first ?? "list"
        switch subcommand {
        case "list":
            let statuses = try service.listEngines()
            return renderList(statuses)
        case "doctor":
            guard let engineName = arguments.dropFirst().first else {
                throw StoreError.invalidManifest("Usage: esh engines doctor <llama.cpp|mlx>")
            }
            let engine = try EngineIdentifier(cliValue: engineName)
            return try renderDoctor(service.status(for: engine))
        default:
            throw StoreError.invalidManifest("Usage: esh engines list | esh engines doctor <llama.cpp|mlx>")
        }
    }

    static func renderList(_ statuses: [EngineStatus]) -> [String] {
        var lines = ["engine              kind      enabled  installed  ready  path"]
        lines += statuses.map { status in
            let kind = status.required ? "required" : "optional"
            return String(
                format: "%-19@ %-9@ %-8@ %-10@ %-6@ %@",
                status.id.rawValue as NSString,
                kind as NSString,
                yesNo(status.enabled) as NSString,
                yesNo(status.installed) as NSString,
                yesNo(status.ready) as NSString,
                (status.executablePath ?? "-") as NSString
            )
        }
        return lines
    }

    static func renderDoctor(_ status: EngineStatus) -> [String] {
        var lines = [
            "engine: \(status.id.rawValue)",
            "name: \(status.name)",
            "kind: \(status.required ? "required" : "optional")",
            "enabled: \(yesNo(status.enabled))",
            "installed: \(yesNo(status.installed))",
            "ready: \(yesNo(status.ready))"
        ]
        if let path = status.executablePath {
            lines.append("path: \(path)")
        }
        if let version = status.version {
            lines.append("version: \(version)")
        }
        if !status.notes.isEmpty {
            lines.append("notes:")
            lines += status.notes.map { "- \($0)" }
        }
        if !status.warnings.isEmpty {
            lines.append("warnings:")
            lines += status.warnings.map { "- \($0)" }
        }
        if let suggestedFix = status.suggestedFix {
            lines.append("suggested_fix: \(suggestedFix)")
        }
        return lines
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? "yes" : "no"
    }
}
