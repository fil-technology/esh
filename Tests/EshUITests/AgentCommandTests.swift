import Foundation
import Testing
import EshCore
@testable import esh

@Suite
struct AgentCommandTests {
    @Test
    func continuationTaskPrefersExplicitTaskThenCurrentThenPendingThenLast() {
        let state = RunState(
            runID: "demo",
            workspaceRootPath: "/tmp/demo",
            pendingTasks: ["inspect refresh path"],
            currentTask: "current task",
            lastTask: "last task"
        )

        #expect(AgentCommand.resolveContinuationTask(requestedTask: "explicit next task", state: state) == "explicit next task")
        #expect(AgentCommand.resolveContinuationTask(requestedTask: "", state: state) == "current task")

        let noCurrent = RunState(
            runID: "demo",
            workspaceRootPath: "/tmp/demo",
            pendingTasks: ["inspect refresh path"],
            currentTask: nil,
            lastTask: "last task"
        )
        #expect(AgentCommand.resolveContinuationTask(requestedTask: "", state: noCurrent) == "inspect refresh path")

        let noPending = RunState(
            runID: "demo",
            workspaceRootPath: "/tmp/demo",
            pendingTasks: [],
            currentTask: nil,
            lastTask: "last task"
        )
        #expect(AgentCommand.resolveContinuationTask(requestedTask: "", state: noPending) == "last task")
    }

    @Test
    func continuationMemoryIncludesSummaryTaskAndNextSteps() {
        let trace = RunTrace(
            state: RunState(
                runID: "demo",
                workspaceRootPath: "/tmp/demo",
                status: "paused",
                discoveredFiles: ["Sources/Auth.swift"],
                findings: ["Read Auth.swift:10-20"],
                decisions: ["Need to patch refresh flow"],
                pendingTasks: ["verify build"],
                currentTask: nil,
                lastTask: "Fix refresh flow",
                lastFinalResponse: "Agent stopped before successful verification."
            ),
            events: [
                RunEvent(runID: "demo", kind: "agent.task.started", detail: "Fix refresh flow"),
                RunEvent(runID: "demo", kind: "run.status", detail: "paused", attributes: ["status": "paused"])
            ]
        )
        let synthesis = RunStateSynthesizer().synthesize(trace: trace)

        let memory = AgentCommand.continuationMemoryText(trace: trace, synthesis: synthesis)

        #expect(memory.contains("Continuation memory for run demo"))
        #expect(memory.contains("last task: Fix refresh flow"))
        #expect(memory.contains("Need to patch refresh flow"))
        #expect(memory.contains("verify build"))
    }
}
