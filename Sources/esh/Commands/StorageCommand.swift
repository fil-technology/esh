import Foundation
import EshCore

/// `esh storage` — inspect and control where large AI assets live.
///
///   esh storage show [--json]
///   esh storage set <path> [--no-move]      relocate assets to <path> (moves existing by default)
///   esh storage use-internal [--no-move]    move assets back to the internal disk
///   esh storage doctor [--json]             validate the configured storage
///   esh storage migrate <path>              alias for `set <path>` (moves existing)
enum StorageCommand {
    static func run(arguments: [String], root: PersistenceRoot) throws {
        let service = StorageService()
        let subcommand = arguments.first ?? "show"
        let rest = Array(arguments.dropFirst())
        let json = rest.contains("--json")

        switch subcommand {
        case "show":
            printReport(service.report(root: root), json: json)
        case "doctor":
            try runDoctor(service: service, root: root, json: json)
        case "set", "migrate":
            let move = !rest.contains("--no-move")
            let positional = rest.filter { !$0.hasPrefix("--") }
            guard let path = positional.first else {
                throw StoreError.invalidManifest("Usage: esh storage \(subcommand) <path> [--no-move]")
            }
            print("Configuring assets storage at \(path)…")
            let newRoot = try service.setAssetsRoot(
                path,
                migrateExisting: move,
                root: root,
                progress: { message in print("  \(message)") }
            )
            print("Assets root is now: \(newRoot.assetsRootURL.path)")
            printReport(service.report(root: newRoot), json: false)
        case "use-internal":
            let move = !rest.contains("--no-move")
            let newRoot = try service.useInternal(
                migrateExisting: move,
                root: root,
                progress: { message in print("  \(message)") }
            )
            print("Assets now live on the internal disk: \(newRoot.assetsRootURL.path)")
            printReport(service.report(root: newRoot), json: false)
        default:
            throw StoreError.invalidManifest(
                "Usage: esh storage [show|set <path>|use-internal|doctor|migrate <path>] [--json] [--no-move]"
            )
        }
    }

    private static func runDoctor(service: StorageService, root: PersistenceRoot, json: Bool) throws {
        let report = service.report(root: root)
        if json {
            printReport(report, json: true)
        } else {
            printReport(report, json: false)
            print("")
            switch report.status {
            case "unavailable":
                print("✗ Storage is UNAVAILABLE: \(report.reason ?? "unknown reason")")
                print("  Reconnect the volume at \(report.assetsRoot), or run `esh storage use-internal`.")
            case "available":
                print("✓ External assets storage is mounted and writable.")
            default:
                print("✓ Assets are on the internal disk.")
            }
            if let free = report.freeBytes {
                print("  Free space: \(ByteFormatting.string(for: free))")
            }
        }
        if report.status == "unavailable" {
            throw CLIHandledError()
        }
    }

    private static func printReport(_ report: StorageReport, json: Bool) {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(report), let text = String(data: data, encoding: .utf8) {
                print(text)
            }
            return
        }

        print("State root (internal): \(report.stateRoot)")
        print("Assets root:           \(report.assetsRoot)\(report.external ? " (external)" : " (internal)")")
        let statusText: String
        switch report.status {
        case "available": statusText = "available"
        case "unavailable": statusText = "UNAVAILABLE — \(report.reason ?? "unknown")"
        default: statusText = "internal"
        }
        print("Status:                \(statusText)")
        if let free = report.freeBytes {
            print("Free space:            \(ByteFormatting.string(for: free))")
        }
        for location in report.locations {
            let size = location.sizeBytes.map { " (\(ByteFormatting.string(for: $0)))" } ?? ""
            let state = location.exists ? "" : " [not created yet]"
            print("  \(location.storageClass.padding(toLength: 8, withPad: " ", startingAt: 0)) \(location.path)\(size)\(state)")
        }
    }
}
