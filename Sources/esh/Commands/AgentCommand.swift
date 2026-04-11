import Foundation
import EshCore

enum AgentCommand {
    static func run(arguments: [String], currentDirectoryURL: URL) async throws {
        guard let subcommand = arguments.first, subcommand == "run" else {
            throw StoreError.invalidManifest("Usage: esh agent run <task> --model <id-or-repo> [--steps N] [--run <id-or-name>]")
        }

        let remaining = Array(arguments.dropFirst())
        let modelIdentifier = try CommandSupport.requiredValue(flag: "--model", in: remaining)
        let steps = Int(CommandSupport.optionalValue(flag: "--steps", in: remaining) ?? "6") ?? 6
        let requestedRunID = CommandSupport.optionalValue(flag: "--run", in: remaining)
        let positional = CommandSupport.positionalArguments(in: remaining, knownFlags: ["--model", "--steps", "--run"])
        guard positional.isEmpty == false else {
            throw StoreError.invalidManifest("Usage: esh agent run <task> --model <id-or-repo> [--steps N] [--run <id-or-name>]")
        }

        let task = positional.joined(separator: " ")
        let root = PersistenceRoot.default()
        let modelStore = FileModelStore(root: root)
        let install = try CommandSupport.resolveInstall(identifier: modelIdentifier, modelStore: modelStore)
        let backend = InferenceBackendRegistry().backend(for: install)
        let runtime = try await backend.loadRuntime(for: install)
        defer { Task { await runtime.unload() } }

        let workspaceRootURL = WorkspaceContextLocator(root: root).workspaceRootURL(from: currentDirectoryURL)
        let runStore = RunStateStore(root: root)
        let runState: RunState
        if let requestedRunID, requestedRunID.isEmpty == false {
            if let loaded = try? runStore.load(runID: requestedRunID, workspaceRootURL: workspaceRootURL) {
                runState = loaded
            } else {
                runState = try runStore.createRun(workspaceRootURL: workspaceRootURL, name: requestedRunID)
            }
        } else {
            runState = try runStore.createRun(workspaceRootURL: workspaceRootURL, name: "agent")
        }
        try? runStore.recordDecision(runID: runState.runID, workspaceRootURL: workspaceRootURL, text: "agent task: \(task)")
        try? runStore.recordPendingTask(runID: runState.runID, workspaceRootURL: workspaceRootURL, text: task)
        try? runStore.updateStatus(runID: runState.runID, workspaceRootURL: workspaceRootURL, status: "in_progress")

        let session = ChatSession(
            name: "agent-\(runState.runID)",
            modelID: install.id,
            backend: install.spec.backend,
            cacheMode: .automatic,
            intent: .agentRun
        )
        let result = try await AgentLoopService().run(
            task: task,
            session: session,
            runtime: runtime,
            workspaceRootURL: workspaceRootURL,
            runID: runState.runID,
            maxSteps: max(steps, 1)
        )

        try? runStore.recordFinding(runID: runState.runID, workspaceRootURL: workspaceRootURL, text: "Agent loop completed \(result.steps.count) step(s)")
        try? runStore.recordCompletedTask(runID: runState.runID, workspaceRootURL: workspaceRootURL, text: task)
        try? runStore.updateStatus(runID: runState.runID, workspaceRootURL: workspaceRootURL, status: "completed")

        print("run: \(runState.runID)")
        print("task: \(task)")
        print("steps: \(result.steps.count)")
        for step in result.steps {
            print("step \(step.index):")
            if let toolCall = step.toolCall {
                print("  tool: \(toolCall.name)")
                let preview = toolCall.input.replacingOccurrences(of: "\n", with: " ").prefix(120)
                print("  input: \(preview)")
            }
            if let toolResult = step.toolResult {
                print("  status: \(toolResult.isError ? "error" : "ok")")
                let outputPreview = toolResult.output.replacingOccurrences(of: "\n", with: " ").prefix(160)
                print("  output: \(outputPreview)")
            }
        }
        print("final:")
        print(result.finalResponse)
    }
}
