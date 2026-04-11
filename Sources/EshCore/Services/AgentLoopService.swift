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
        var verificationRequired = false
        var lastVerificationFailure: String?

        for index in 1...maxSteps {
            let response = try await collectReply(runtime: runtime, session: workingSession)
            workingSession.messages.append(Message(role: .assistant, text: response))

            if let parsed = parser.parse(response) {
                switch parsed {
                case let .final(text):
                    if verificationRequired {
                        let retryMessage = verificationRetryMessage(lastFailure: lastVerificationFailure)
                        if index == maxSteps {
                            let failureSuffix = lastVerificationFailure.map { "\nLast verification failure:\n\($0)" } ?? ""
                            return AgentLoopResult(
                                task: task,
                                finalResponse: "Agent stopped before successful verification.\nCandidate final response:\n\(text)\(failureSuffix)",
                                steps: steps,
                                runID: runID
                            )
                        }
                        workingSession.messages.append(Message(role: .tool, text: retryMessage))
                        steps.append(
                            AgentLoopStep(
                                index: index,
                                assistantResponse: response,
                                toolCall: nil,
                                toolResult: AgentToolResult(
                                    name: "verification",
                                    output: "Final answer rejected because verification is still required after file edits or a failed verification step.",
                                    isError: true
                                )
                            )
                        )
                        continue
                    }
                    steps.append(AgentLoopStep(index: index, assistantResponse: response, toolCall: nil, toolResult: nil))
                    return AgentLoopResult(task: task, finalResponse: text, steps: steps, runID: runID)
                case let .tool(call):
                    let result = try toolService.execute(call: call, workspaceRootURL: workspaceRootURL, runID: runID)
                    if requiresVerification(for: call), result.isError == false {
                        verificationRequired = true
                    }
                    if isVerificationTool(call.name) {
                        if result.isError {
                            verificationRequired = true
                            lastVerificationFailure = result.output
                        } else {
                            verificationRequired = false
                            lastVerificationFailure = nil
                        }
                    }
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
        After write_file or edit_file, run verify_build or verify_tests before giving a final answer.
        If verification fails, repair the issue and verify again before finishing.
        Use shell only for safe repo inspection commands.

        \(toolService.toolPrompt())
        """
    }

    private func toolMessageText(for result: AgentToolResult) -> String {
        let status = result.isError ? "error" : "ok"
        return "tool: \(result.name)\nstatus: \(status)\nresult:\n\(result.output)"
    }

    private func isVerificationTool(_ name: String) -> Bool {
        ["verify_build", "verify_tests"].contains(name)
    }

    private func requiresVerification(for call: AgentToolCall) -> Bool {
        guard ["write_file", "edit_file"].contains(call.name) else {
            return false
        }
        guard let path = parsedPath(from: call.input) else {
            return true
        }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let codeExtensions: Set<String> = [
            "swift", "m", "mm", "c", "cc", "cpp", "h", "hpp",
            "js", "jsx", "ts", "tsx",
            "py", "rb", "go", "rs", "java", "kt", "kts", "cs", "php", "scala", "sh"
        ]
        return codeExtensions.contains(ext)
    }

    private func parsedPath(from input: String) -> String? {
        for line in input.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("path:") {
                return String(trimmed.dropFirst("path:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func verificationRetryMessage(lastFailure: String?) -> String {
        var lines = [
            "Verification is still required before you can give a final answer.",
            "After file edits, run verify_build or verify_tests and only finish once verification succeeds."
        ]
        if let lastFailure, lastFailure.isEmpty == false {
            lines.append("Last verification failure:")
            lines.append(lastFailure)
        }
        lines.append("Reply with exactly one fenced tool or final block.")
        return lines.joined(separator: "\n")
    }
}
