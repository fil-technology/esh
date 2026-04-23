import Foundation
import EshCore

enum ReadCommand {
    static func run(arguments: [String], currentDirectoryURL: URL) throws {
        let locator = WorkspaceContextLocator()
        let workspaceRootURL = locator.workspaceRootURL(from: currentDirectoryURL)
        let index = try ContextStore(locator: locator).load(workspaceRootURL: workspaceRootURL)
        let service = ContextReadService()
        let runID = CommandSupport.optionalValue(flag: "--run", in: arguments)
        let filteredArguments = CommandSupport.removingKnownFlags(["--run"], from: arguments)

        guard let subcommand = filteredArguments.first else {
            throw StoreError.invalidManifest("Usage: esh read symbol <name> | esh read references <name> | esh read related <name-or-path> | esh read file <path> --range start:end")
        }

        switch subcommand {
        case "symbol":
            let positional = CommandSupport.positionalArguments(in: Array(filteredArguments.dropFirst()), knownFlags: [])
            guard let symbolName = positional.first else {
                throw StoreError.invalidManifest("Usage: esh read symbol <name>")
            }
            let result = try service.readSymbol(symbolName, from: index, workspaceRootURL: workspaceRootURL)
            if let runID {
                try? RunStateStore().recordSymbolRead(runID: runID, workspaceRootURL: workspaceRootURL, result: result)
            }
            print("symbol: \(result.symbol.name)")
            print("kind: \(result.symbol.kind)")
            print("file: \(result.fileURL.path)")
            print("range: \(result.range.lineStart):\(result.range.lineEnd)")
            renderLines(result.lines, startLine: result.range.lineStart)
        case "references":
            let positional = CommandSupport.positionalArguments(in: Array(filteredArguments.dropFirst()), knownFlags: ["--limit"])
            guard let symbolName = positional.first else {
                throw StoreError.invalidManifest("Usage: esh read references <name> [--limit N]")
            }
            let limit = Int(CommandSupport.optionalValue(flag: "--limit", in: Array(filteredArguments.dropFirst())) ?? "20") ?? 20
            let results = try service.findReferences(symbolName, in: index, workspaceRootURL: workspaceRootURL, limit: limit)
            if results.isEmpty {
                print("No references found for \(symbolName).")
                return
            }
            for result in results {
                let relativePath = relativePath(for: result.fileURL, workspaceRootURL: workspaceRootURL)
                if let runID {
                    try? RunStateStore().recordFileRead(runID: runID, workspaceRootURL: workspaceRootURL, relativePath: relativePath, range: result.range)
                }
                print("file: \(result.fileURL.path)")
                print("range: \(result.range.lineStart):\(result.range.lineEnd)")
                renderLines(result.lines, startLine: result.range.lineStart)
                print("")
            }
        case "related":
            let positional = CommandSupport.positionalArguments(in: Array(filteredArguments.dropFirst()), knownFlags: ["--limit"])
            guard let target = positional.first else {
                throw StoreError.invalidManifest("Usage: esh read related <name-or-path> [--limit N]")
            }
            let limit = Int(CommandSupport.optionalValue(flag: "--limit", in: Array(filteredArguments.dropFirst())) ?? "5") ?? 5
            let results = try service.readRelated(target, in: index, workspaceRootURL: workspaceRootURL, limit: limit)
            for result in results {
                let relativePath = relativePath(for: result.fileURL, workspaceRootURL: workspaceRootURL)
                if let runID {
                    try? RunStateStore().recordFileRead(runID: runID, workspaceRootURL: workspaceRootURL, relativePath: relativePath, range: result.range)
                }
                print("file: \(result.fileURL.path)")
                print("range: \(result.range.lineStart):\(result.range.lineEnd)")
                renderLines(result.lines, startLine: result.range.lineStart)
                print("")
            }
        case "file":
            let rangeValue = try CommandSupport.requiredValue(flag: "--range", in: Array(filteredArguments.dropFirst()))
            let positional = CommandSupport.positionalArguments(in: Array(filteredArguments.dropFirst()), knownFlags: ["--range"])
            guard let relativePath = positional.first else {
                throw StoreError.invalidManifest("Usage: esh read file <path> --range start:end")
            }
            let range = try parseRange(rangeValue)
            let result = try service.readFile(relativePath, range: range, workspaceRootURL: workspaceRootURL)
            if let runID {
                try? RunStateStore().recordFileRead(runID: runID, workspaceRootURL: workspaceRootURL, relativePath: relativePath, range: range)
            }
            print("file: \(result.fileURL.path)")
            print("range: \(result.range.lineStart):\(result.range.lineEnd)")
            renderLines(result.lines, startLine: result.range.lineStart)
        default:
            throw StoreError.invalidManifest("Unknown read subcommand: \(subcommand)")
        }
    }

    private static func parseRange(_ value: String) throws -> SourceRange {
        let parts = value.split(separator: ":").map(String.init)
        guard parts.count == 2, let start = Int(parts[0]), let end = Int(parts[1]), start > 0, end >= start else {
            throw StoreError.invalidManifest("Invalid range \(value). Expected start:end.")
        }
        return SourceRange(lineStart: start, lineEnd: end)
    }

    private static func renderLines(_ lines: [String], startLine: Int) {
        for (offset, line) in lines.enumerated() {
            print("\(startLine + offset)\t\(line)")
        }
    }

    private static func relativePath(for fileURL: URL, workspaceRootURL: URL) -> String {
        let root = workspaceRootURL.path.hasSuffix("/") ? workspaceRootURL.path : workspaceRootURL.path + "/"
        if fileURL.path.hasPrefix(root) {
            return String(fileURL.path.dropFirst(root.count))
        }
        return fileURL.lastPathComponent
    }
}
