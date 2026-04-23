import Foundation
import EshCore

enum AgentCommand {
    static func run(arguments: [String], currentDirectoryURL: URL) async throws {
        guard let subcommand = arguments.first, ["run", "continue"].contains(subcommand) else {
            throw StoreError.invalidManifest("Usage: esh agent run <task> --model <id-or-repo> [--steps N] [--run <id-or-name>] | esh agent continue --run <id> --model <id-or-repo> [--steps N] [task]")
        }

        let remaining = Array(arguments.dropFirst())
        let modelIdentifier = try CommandSupport.requiredValue(flag: "--model", in: remaining)
        let steps = Int(CommandSupport.optionalValue(flag: "--steps", in: remaining) ?? "6") ?? 6
        let requestedRunID = CommandSupport.optionalValue(flag: "--run", in: remaining)
        let positional = CommandSupport.positionalArguments(in: remaining, knownFlags: ["--model", "--steps", "--run"])
        let root = PersistenceRoot.default()
        let modelStore = FileModelStore(root: root)
        let install = try CommandSupport.resolveInstall(identifier: modelIdentifier, modelStore: modelStore)
        let backend = InferenceBackendRegistry().backend(for: install)
        let runtime = try await backend.loadRuntime(for: install)
        defer { Task { await runtime.unload() } }

        let workspaceRootURL = WorkspaceContextLocator(root: root).workspaceRootURL(from: currentDirectoryURL)
        let runStore = RunStateStore(root: root)
        let runState: RunState
        let task: String
        let session: ChatSession

        switch subcommand {
        case "run":
            guard positional.isEmpty == false else {
                throw StoreError.invalidManifest("Usage: esh agent run <task> --model <id-or-repo> [--steps N] [--run <id-or-name>]")
            }
            task = positional.joined(separator: " ")
            if let requestedRunID, requestedRunID.isEmpty == false {
                if let loaded = try? runStore.load(runID: requestedRunID, workspaceRootURL: workspaceRootURL) {
                    runState = loaded
                } else {
                    runState = try runStore.createRun(workspaceRootURL: workspaceRootURL, name: requestedRunID)
                }
            } else {
                runState = try runStore.createRun(workspaceRootURL: workspaceRootURL, name: "agent")
            }
            session = ChatSession(
                name: "agent-\(runState.runID)",
                modelID: install.id,
                backend: install.spec.backend,
                cacheMode: .automatic,
                intent: .agentRun
            )
        case "continue":
            guard let requestedRunID, requestedRunID.isEmpty == false else {
                throw StoreError.invalidManifest("Usage: esh agent continue --run <id> --model <id-or-repo> [--steps N] [task]")
            }
            runState = try runStore.load(runID: requestedRunID, workspaceRootURL: workspaceRootURL)
            task = resolveContinuationTask(requestedTask: positional.joined(separator: " "), state: runState)
            let trace = try runStore.exportTrace(runID: runState.runID, workspaceRootURL: workspaceRootURL)
            session = continuationSession(
                runID: runState.runID,
                install: install,
                trace: trace
            )
        default:
            throw StoreError.invalidManifest("Unknown agent subcommand: \(subcommand)")
        }

        try? runStore.beginAgentTask(runID: runState.runID, workspaceRootURL: workspaceRootURL, task: task)
        try? runStore.recordDecision(runID: runState.runID, workspaceRootURL: workspaceRootURL, text: "agent task: \(task)")
        try? runStore.updateStatus(runID: runState.runID, workspaceRootURL: workspaceRootURL, status: "in_progress")
        let result = try await AgentLoopService(runStateStore: runStore).run(
            task: task,
            session: session,
            runtime: runtime,
            workspaceRootURL: workspaceRootURL,
            runID: runState.runID,
            maxSteps: max(steps, 1)
        )

        try? runStore.recordFinding(runID: runState.runID, workspaceRootURL: workspaceRootURL, text: "Agent loop completed \(result.steps.count) step(s)")
        let finalStatus = result.finalResponse.hasPrefix("Agent stopped") ? "paused" : "completed"
        try? runStore.finishAgentTask(
            runID: runState.runID,
            workspaceRootURL: workspaceRootURL,
            task: task,
            finalResponse: result.finalResponse,
            status: finalStatus
        )
        try? runStore.updateStatus(runID: runState.runID, workspaceRootURL: workspaceRootURL, status: finalStatus)

        print("run: \(runState.runID)")
        print("task: \(task)")
        print("status: \(finalStatus)")
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

    static func resolveContinuationTask(requestedTask: String, state: RunState) -> String {
        let trimmed = requestedTask.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty == false {
            return trimmed
        }
        if let currentTask = state.currentTask, currentTask.isEmpty == false {
            return currentTask
        }
        if let pending = state.pendingTasks.first(where: { $0.isEmpty == false }) {
            return pending
        }
        if let lastTask = state.lastTask, lastTask.isEmpty == false {
            return lastTask
        }
        return "Continue the previous agent investigation"
    }

    static func continuationSession(
        runID: String,
        install: ModelInstall,
        trace: RunTrace
    ) -> ChatSession {
        var session = ChatSession(
            name: "agent-\(runID)",
            modelID: install.id,
            backend: install.spec.backend,
            cacheMode: .automatic,
            intent: .agentRun
        )
        let synthesis = RunStateSynthesizer().synthesize(trace: trace)
        let memory = continuationMemoryText(trace: trace, synthesis: synthesis)
        if memory.isEmpty == false {
            session.messages.append(Message(role: .system, text: memory))
        }
        return session
    }

    static func continuationMemoryText(trace: RunTrace, synthesis: RunSynthesis) -> String {
        var lines: [String] = [
            "Continuation memory for run \(trace.state.runID):",
            "status: \(synthesis.status)",
            "summary: \(synthesis.compactedSummary ?? synthesis.summary)"
        ]
        if let lastTask = trace.state.lastTask, lastTask.isEmpty == false {
            lines.append("last task: \(lastTask)")
        }
        if let lastFinalResponse = trace.state.lastFinalResponse, lastFinalResponse.isEmpty == false {
            lines.append("last final response: \(String(lastFinalResponse.prefix(220)))")
        }
        if synthesis.findings.isEmpty == false {
            lines.append("findings: \(synthesis.findings.prefix(3).joined(separator: " | "))")
        }
        if synthesis.decisions.isEmpty == false {
            lines.append("decisions: \(synthesis.decisions.prefix(3).joined(separator: " | "))")
        }
        if synthesis.suggestedNextSteps.isEmpty == false {
            lines.append("next steps: \(synthesis.suggestedNextSteps.prefix(4).joined(separator: " | "))")
        }
        return lines.joined(separator: "\n")
    }
}
