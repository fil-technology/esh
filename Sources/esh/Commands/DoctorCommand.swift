import Foundation
import EshCore

enum DoctorCommand {
    static func run(arguments: [String] = []) throws {
        let root = PersistenceRoot.default()
        let version = AppVersionResolver.currentVersion()
        let report = DoctorService().report(root: root, version: version)

        if arguments.contains("--json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(report), let text = String(data: data, encoding: .utf8) {
                print(text)
            }
            if report.status != "ok" { throw CLIHandledError() }
            return
        }

        for line in humanLines(report: report, root: root) {
            print(line)
        }
        if report.status != "ok" { throw CLIHandledError() }
    }

    /// Retained for callers/tests that only want the text engine section.
    static func outputLines() throws -> [String] {
        let root = PersistenceRoot.default()
        let report = DoctorService().report(root: root, version: AppVersionResolver.currentVersion())
        return humanLines(report: report, root: root)
    }

    private static func humanLines(report: DoctorReport, root: PersistenceRoot) -> [String] {
        var lines: [String] = []
        lines.append("status: \(report.status)")
        if let version = report.version { lines.append("version: \(version)") }
        lines.append("macos: \(report.macOS)")
        if let chip = report.host.chipDescription { lines.append("chip: \(chip)") }
        if let total = report.host.totalMemoryGB {
            let avail = report.host.availableMemoryGB.map { String(format: "%.1f", $0) } ?? "?"
            lines.append(String(format: "memory: %.1f GB total, %@ GB available", total, avail))
        }

        // Storage
        lines.append("")
        lines.append("storage:")
        lines.append("  state_root: \(report.stateRoot)")
        let assetsSuffix = report.storage.external ? " (external)" : " (internal)"
        lines.append("  assets_root: \(report.storage.assetsRoot)\(assetsSuffix)")
        switch report.storage.status {
        case "unavailable":
            lines.append("  status: UNAVAILABLE — \(report.storage.reason ?? "unknown")")
            lines.append("  fix: reconnect the volume, or run `esh storage use-internal`")
        case "available":
            lines.append("  status: available")
        default:
            lines.append("  status: internal")
        }
        if let free = report.storage.freeBytes {
            lines.append("  free: \(ByteFormatting.string(for: free))")
        }

        // Models
        lines.append("")
        lines.append("models:")
        lines.append("  installed: \(report.models.installedCount)")
        if let def = report.models.defaultModel { lines.append("  default: \(def)") }
        if !report.models.incomplete.isEmpty {
            lines.append("  incomplete/corrupt: \(report.models.incomplete.joined(separator: ", "))")
            lines.append("  fix: `esh model remove <id>` then reinstall")
        }

        // Config
        lines.append("")
        lines.append("config: \(report.configPath)")

        // Engines
        lines.append("")
        lines.append("engines:")
        lines += report.engines.map { status in
            "- \(status.id.rawValue): \(status.ready ? "ready" : "not_ready")\(status.required ? " required" : " optional")"
                + (status.version.map { " (\($0))" } ?? "")
        }
        for status in report.engines where !status.notes.isEmpty || !status.warnings.isEmpty || status.suggestedFix != nil {
            lines.append("")
            lines += EnginesCommand.renderDoctor(status)
        }
        return lines
    }
}
