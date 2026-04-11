import Foundation

public struct AgentLoopService: Sendable {
    private let chatService: ChatService
    private let parser: AgentResponseParser
    private let toolService: AgentToolService
    private let contextStore: ContextStore
    private let packageService: ContextPackageService
    private let planningService: ContextPlanningService

    public init(
        chatService: ChatService = .init(),
        parser: AgentResponseParser = .init(),
        toolService: AgentToolService = .init(),
        contextStore: ContextStore = .init(),
        packageService: ContextPackageService = .init(),
        planningService: ContextPlanningService = .init()
    ) {
        self.chatService = chatService
        self.parser = parser
        self.toolService = toolService
        self.contextStore = contextStore
        self.packageService = packageService
        self.planningService = planningService
    }

    public func run(
        task: String,
        session: ChatSession,
        runtime: any BackendRuntime,
        workspaceRootURL: URL,
        runID: String? = nil,
        maxSteps: Int = 6
    ) async throws -> AgentLoopResult {
        var workingSession = session
        workingSession.intent = .agentRun
        workingSession.messages.append(Message(role: .system, text: systemPrompt()))
        workingSession.messages.append(Message(role: .user, text: try initialTaskPrompt(task: task, session: workingSession, workspaceRootURL: workspaceRootURL)))

        var steps: [AgentLoopStep] = []

        for index in 1...maxSteps {
            let response = try await collectReply(runtime: runtime, session: workingSession)
            workingSession.messages.append(Message(role: .assistant, text: response))

            if let parsed = parser.parse(response) {
                switch parsed {
                case let .final(text):
                    steps.append(AgentLoopStep(index: index, assistantResponse: response, toolCall: nil, toolResult: nil))
                    return AgentLoopResult(task: task, finalResponse: text, steps: steps, runID: runID)
                case let .tool(call):
                    let result = try toolService.execute(call: call, workspaceRootURL: workspaceRootURL, runID: runID)
                    workingSession.messages.append(
                        Message(role: .tool, text: toolMessageText(for: result))
                    )
                    steps.append(AgentLoopStep(index: index, assistantResponse: response, toolCall: call, toolResult: result))
                    continue
                }
            }

            if index == maxSteps {
                return AgentLoopResult(task: task, finalResponse: response, steps: steps, runID: runID)
            }

            let retryMessage = """
            Your previous response was not in the required format.
            Reply with exactly one fenced block:
            ```tool
            name: <tool-name>
            input:
            <tool-input>
            ```
            or
            ```final
            <final-answer>
            ```
            """
            workingSession.messages.append(Message(role: .tool, text: retryMessage))
            steps.append(AgentLoopStep(index: index, assistantResponse: response, toolCall: nil, toolResult: AgentToolResult(name: "format", output: "Model response did not follow the tool/final protocol.", isError: true)))
        }

        return AgentLoopResult(task: task, finalResponse: "Agent stopped without a final answer.", steps: steps, runID: runID)
    }

    private func initialTaskPrompt(task: String, session: ChatSession, workspaceRootURL: URL) throws -> String {
        guard let index = try? contextStore.load(workspaceRootURL: workspaceRootURL) else {
            return task
        }
        let resolution = try packageService.resolveBrief(
            task: task,
            index: index,
            workspaceRootURL: workspaceRootURL,
            limit: 4,
            snippetCount: 2,
            modelID: session.modelID,
            intent: .agentRun,
            cacheMode: session.cacheMode
        )
        return planningService.augmentedPrompt(userPrompt: task, brief: resolution.brief)
    }

    private func collectReply(runtime: any BackendRuntime, session: ChatSession) async throws -> String {
        let stream = chatService.streamReply(
            runtime: runtime,
            session: session,
            config: GenerationConfig(maxTokens: 400, temperature: 0.2)
        )
        var combined = ""
        for try await chunk in stream {
            combined += chunk
        }
        return combined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func systemPrompt() -> String {
        """
        You are the autonomous coding agent mode for esh.
        Investigate repository tasks step by step using the available tools.
        Use tools before answering when the task depends on repository facts.
        Prefer context_plan or context_query before broad file reads.
        Prefer read_symbol and read_related over reading whole files when possible.
        Use shell only for safe verification commands.

        \(toolService.toolPrompt())
        """
    }

    private func toolMessageText(for result: AgentToolResult) -> String {
        let status = result.isError ? "error" : "ok"
        return "tool: \(result.name)\nstatus: \(status)\nresult:\n\(result.output)"
    }
}
