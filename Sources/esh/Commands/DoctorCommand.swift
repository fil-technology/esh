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
        let service = EngineOrchestratorService(root: root)
        let statuses = try service.listEngines()
        let required = statuses.filter(\.required)
        let allRequiredReady = required.allSatisfy(\.ready)

        var lines = [
            "status: \(allRequiredReady ? "ok" : "degraded")",
            "persistence_root: \(root.rootURL.path)",
            "config: \(EshConfigStore(root: root).configURL.path)",
            "engines:"
        ]
        lines += statuses.map { status in
            "- \(status.id.rawValue): \(status.ready ? "ready" : "not_ready")\(status.required ? " required" : " optional")"
        }
        for status in statuses where !status.notes.isEmpty || !status.warnings.isEmpty || status.suggestedFix != nil {
            lines.append("")
            lines += EnginesCommand.renderDoctor(status)
        }
        return lines
    }
}
