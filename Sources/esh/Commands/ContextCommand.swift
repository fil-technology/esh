import Foundation
import EshCore

enum ContextCommand {
    static func run(arguments: [String], currentDirectoryURL: URL) throws {
        let locator = WorkspaceContextLocator()
        let workspaceRootURL = locator.workspaceRootURL(from: currentDirectoryURL)
        let store = ContextStore(locator: locator)
        let runID = CommandSupport.optionalValue(flag: "--run", in: arguments)
        let filteredArguments = CommandSupport.removingKnownFlags(["--run"], from: arguments)

        guard let subcommand = filteredArguments.first else {
            try showStatus(workspaceRootURL: workspaceRootURL, store: store)
            return
        }

        switch subcommand {
        case "build":
            let index = try ContextIndexer().buildIndex(workspaceRootURL: workspaceRootURL)
            try store.save(index: index, workspaceRootURL: workspaceRootURL)
            print("workspace: \(workspaceRootURL.path)")
            print("files: \(index.files.count)")
            print("symbols: \(index.symbols.count)")
            print("edges: \(index.edges.count)")
            print("built_at: \(ISO8601DateFormatter().string(from: index.builtAt))")
        case "status":
            try showStatus(workspaceRootURL: workspaceRootURL, store: store)
        case "query":
            let positional = CommandSupport.positionalArguments(in: Array(filteredArguments.dropFirst()), knownFlags: ["--limit"])
            guard positional.isEmpty == false else {
                throw StoreError.invalidManifest("Usage: esh context query <text> [--limit N] [--run <id>]")
            }
            let limit = Int(CommandSupport.optionalValue(flag: "--limit", in: Array(filteredArguments.dropFirst())) ?? "10") ?? 10
            let index = try store.load(workspaceRootURL: workspaceRootURL)
            let query = positional.joined(separator: " ")
            let results = ContextQueryEngine().query(query, in: index, limit: limit)
            if let runID {
                try? RunStateStore().recordQuery(runID: runID, workspaceRootURL: workspaceRootURL, query: query, results: results)
            }
            if results.isEmpty {
                print("No ranked context results for \"\(query)\".")
                return
            }
            for (offset, result) in results.enumerated() {
                print("\(offset + 1). \(result.filePath)")
                print("   score: \(String(format: "%.1f", result.score))")
                print("   reasons: \(result.reasons.joined(separator: ", "))")
                if result.relatedSymbols.isEmpty == false {
                    print("   symbols: \(result.relatedSymbols.joined(separator: ", "))")
                }
                if let firstRange = result.suggestedRanges.first {
                    print("   range: \(firstRange.lineStart):\(firstRange.lineEnd)")
                }
            }
        default:
            throw StoreError.invalidManifest("Unknown context subcommand: \(subcommand)")
        }
    }

    private static func showStatus(workspaceRootURL: URL, store: ContextStore) throws {
        let status = try store.status(workspaceRootURL: workspaceRootURL)
        print("workspace: \(status.workspaceRootPath)")
        print("built_at: \(ISO8601DateFormatter().string(from: status.builtAt))")
        print("files: \(status.fileCount)")
        print("symbols: \(status.symbolCount)")
        print("edges: \(status.edgeCount)")
    }
}
