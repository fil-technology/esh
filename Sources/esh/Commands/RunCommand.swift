import Foundation
import EshCore

enum RunCommand {
    static func run(arguments: [String], currentDirectoryURL: URL) throws {
        let workspaceRootURL = WorkspaceContextLocator().workspaceRootURL(from: currentDirectoryURL)
        let store = RunStateStore()

        guard let subcommand = arguments.first else {
            throw StoreError.invalidManifest("Usage: esh run start [name] | esh run status <run-id>")
        }

        switch subcommand {
        case "start":
            let positional = CommandSupport.positionalArguments(in: Array(arguments.dropFirst()), knownFlags: [])
            let name = positional.first
            let state = try store.createRun(workspaceRootURL: workspaceRootURL, name: name)
            print("run: \(state.runID)")
            print("workspace: \(state.workspaceRootPath)")
            print("created_at: \(ISO8601DateFormatter().string(from: state.createdAt))")
        case "status":
            let positional = CommandSupport.positionalArguments(in: Array(arguments.dropFirst()), knownFlags: [])
            guard let runID = positional.first else {
                throw StoreError.invalidManifest("Usage: esh run status <run-id>")
            }
            let state = try store.load(runID: runID, workspaceRootURL: workspaceRootURL)
            let events = try store.loadEvents(runID: runID, workspaceRootURL: workspaceRootURL)
            print("run: \(state.runID)")
            print("workspace: \(state.workspaceRootPath)")
            print("discovered_files: \(state.discoveredFiles.count)")
            print("discovered_symbols: \(state.discoveredSymbols.count)")
            print("decisions: \(state.decisions.count)")
            print("pending_tasks: \(state.pendingTasks.count)")
            print("completed_tasks: \(state.completedTasks.count)")
            print("events: \(events.count)")
            if state.discoveredFiles.isEmpty == false {
                print("files_sample: \(state.discoveredFiles.prefix(5).joined(separator: ", "))")
            }
            if state.discoveredSymbols.isEmpty == false {
                print("symbols_sample: \(state.discoveredSymbols.prefix(5).joined(separator: ", "))")
            }
        default:
            throw StoreError.invalidManifest("Unknown run subcommand: \(subcommand)")
        }
    }
}
