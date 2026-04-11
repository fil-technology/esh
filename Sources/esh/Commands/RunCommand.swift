import Foundation
import EshCore

enum RunCommand {
    static func run(arguments: [String], currentDirectoryURL: URL) throws {
        let workspaceRootURL = WorkspaceContextLocator().workspaceRootURL(from: currentDirectoryURL)
        let store = RunStateStore()

        guard let subcommand = arguments.first else {
            throw StoreError.invalidManifest("Usage: esh run start [name] | esh run status <run-id> | esh run note <run-id> [--hypothesis <text>] [--finding <text>] [--decision <text>] [--pending <text>] [--complete <text>] [--status <value>] | esh run export <run-id>")
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
            let synthesis = RunStateSynthesizer().synthesize(state: state, events: events)
            print("run: \(state.runID)")
            print("workspace: \(state.workspaceRootPath)")
            print("status: \(synthesis.status)")
            print("discovered_files: \(state.discoveredFiles.count)")
            print("discovered_symbols: \(state.discoveredSymbols.count)")
            print("hypotheses: \(state.hypotheses.count)")
            print("findings: \(state.findings.count)")
            print("decisions: \(state.decisions.count)")
            print("pending_tasks: \(state.pendingTasks.count)")
            print("completed_tasks: \(state.completedTasks.count)")
            print("events: \(events.count)")
            print("summary: \(synthesis.summary)")
            if state.discoveredFiles.isEmpty == false {
                print("files_sample: \(state.discoveredFiles.prefix(5).joined(separator: ", "))")
            }
            if state.discoveredSymbols.isEmpty == false {
                print("symbols_sample: \(state.discoveredSymbols.prefix(5).joined(separator: ", "))")
            }
            if synthesis.hypotheses.isEmpty == false {
                print("hypotheses_sample: \(synthesis.hypotheses.joined(separator: " | "))")
            }
            if synthesis.findings.isEmpty == false {
                print("findings_sample: \(synthesis.findings.joined(separator: " | "))")
            }
            if synthesis.openQuestions.isEmpty == false {
                print("open_questions: \(synthesis.openQuestions.joined(separator: " | "))")
            }
            if synthesis.suggestedNextSteps.isEmpty == false {
                print("next_steps: \(synthesis.suggestedNextSteps.joined(separator: " | "))")
            }
            if synthesis.transitions.isEmpty == false {
                print("transitions: \(synthesis.transitions.map { "\($0.phase): \($0.detail)" }.joined(separator: " | "))")
            }
        case "note":
            let remaining = Array(arguments.dropFirst())
            let positional = CommandSupport.positionalArguments(
                in: remaining,
                knownFlags: ["--hypothesis", "--finding", "--decision", "--pending", "--complete", "--status"]
            )
            guard let runID = positional.first else {
                throw StoreError.invalidManifest("Usage: esh run note <run-id> [--hypothesis <text>] [--finding <text>] [--decision <text>] [--pending <text>] [--complete <text>] [--status <value>]")
            }

            let hypothesis = CommandSupport.optionalValue(flag: "--hypothesis", in: remaining)
            let finding = CommandSupport.optionalValue(flag: "--finding", in: remaining)
            let decision = CommandSupport.optionalValue(flag: "--decision", in: remaining)
            let pending = CommandSupport.optionalValue(flag: "--pending", in: remaining)
            let complete = CommandSupport.optionalValue(flag: "--complete", in: remaining)
            let status = CommandSupport.optionalValue(flag: "--status", in: remaining)

            guard [hypothesis, finding, decision, pending, complete, status].contains(where: { $0?.isEmpty == false }) else {
                throw StoreError.invalidManifest("Provide at least one note flag for esh run note.")
            }

            if let hypothesis, hypothesis.isEmpty == false {
                try store.recordHypothesis(runID: runID, workspaceRootURL: workspaceRootURL, text: hypothesis)
            }
            if let finding, finding.isEmpty == false {
                try store.recordFinding(runID: runID, workspaceRootURL: workspaceRootURL, text: finding)
            }
            if let decision, decision.isEmpty == false {
                try store.recordDecision(runID: runID, workspaceRootURL: workspaceRootURL, text: decision)
            }
            if let pending, pending.isEmpty == false {
                try store.recordPendingTask(runID: runID, workspaceRootURL: workspaceRootURL, text: pending)
            }
            if let complete, complete.isEmpty == false {
                try store.recordCompletedTask(runID: runID, workspaceRootURL: workspaceRootURL, text: complete)
            }
            if let status, status.isEmpty == false {
                try store.updateStatus(runID: runID, workspaceRootURL: workspaceRootURL, status: status)
            }

            let state = try store.load(runID: runID, workspaceRootURL: workspaceRootURL)
            print("run: \(state.runID)")
            print("status: \(state.status)")
            print("updated_at: \(ISO8601DateFormatter().string(from: state.updatedAt))")
        case "export":
            let positional = CommandSupport.positionalArguments(in: Array(arguments.dropFirst()), knownFlags: [])
            guard let runID = positional.first else {
                throw StoreError.invalidManifest("Usage: esh run export <run-id>")
            }
            let trace = try store.exportTrace(runID: runID, workspaceRootURL: workspaceRootURL)
            let data = try JSONCoding.encoder.encode(trace)
            if let output = String(data: data, encoding: .utf8) {
                print(output)
            }
        default:
            throw StoreError.invalidManifest("Unknown run subcommand: \(subcommand)")
        }
    }
}
