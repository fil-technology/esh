import Foundation
import EshCore

/// `esh model import <path> [--id <id>] [--move]` — register a local MLX directory or GGUF file as
/// a first-class model without re-downloading.
enum ModelImportCommand {
    static func run(arguments: [String], root: PersistenceRoot, currentDirectoryURL: URL) throws {
        let idOverride = CommandSupport.optionalValue(flag: "--id", in: arguments)
        let move = arguments.contains("--move")
        let positional = CommandSupport.positionalArguments(in: arguments, knownFlags: ["--id"])
            .filter { !$0.hasPrefix("--") }
        guard let pathArg = positional.first else {
            throw StoreError.invalidManifest("Usage: esh model import <path> [--id <id>] [--move]")
        }
        let source = PathResolving.url(from: pathArg, base: currentDirectoryURL)
        let service = LocalModelImportService()
        print("\(move ? "Moving" : "Copying") \(source.lastPathComponent) into the model store…")
        let install = try service.importModel(from: source, id: idOverride, move: move, root: root)
        print("Imported \(install.id) [\(install.spec.backend.rawValue)] — \(ByteFormatting.string(for: install.sizeBytes))")
        print("  path: \(install.installPath)")
        print("Use it: esh chat --model \(install.id)")
    }
}

/// `esh model scan [--clean]` — discover model directories already present under the store (e.g. on
/// an external SSD) and register them; with `--clean`, also remove orphaned partial-download
/// directories.
enum ModelScanCommand {
    static func run(arguments: [String], root: PersistenceRoot, currentDirectoryURL: URL) throws {
        let service = LocalModelImportService()
        let positional = CommandSupport.positionalArguments(in: arguments, knownFlags: [])
            .filter { !$0.hasPrefix("--") }

        // `esh model scan <dir>` bulk-imports a folder of models.
        if let dirArg = positional.first {
            let dir = PathResolving.url(from: dirArg, base: currentDirectoryURL, isDirectory: true)
            let move = arguments.contains("--move")
            let imported = try service.importDirectory(dir, root: root, move: move)
            if imported.isEmpty {
                print("No importable models found under \(dir.path).")
            } else {
                for install in imported {
                    print("Imported \(install.id) [\(install.spec.backend.rawValue)] — \(ByteFormatting.string(for: install.sizeBytes))")
                }
            }
            return
        }

        let result = try service.scanStore(root: root)
        if result.registered.isEmpty && result.orphans.isEmpty {
            print("No unregistered models or orphaned directories found.")
            return
        }
        if !result.registered.isEmpty {
            print("Registered \(result.registered.count) model(s) found on storage: \(result.registered.joined(separator: ", "))")
        }
        if !result.orphans.isEmpty {
            print("Found \(result.orphans.count) orphaned/partial install director(ies): \(result.orphans.joined(separator: ", "))")
            if arguments.contains("--clean") {
                let removed = try service.cleanupOrphans(root: root, ids: result.orphans)
                print("Removed \(removed.count): \(removed.joined(separator: ", "))")
            } else {
                print("Run `esh model scan --clean` to remove them.")
            }
        }
    }
}
