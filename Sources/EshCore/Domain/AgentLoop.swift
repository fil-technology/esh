import Foundation

public struct AgentToolCall: Codable, Hashable, Sendable {
    public let name: String
    public let input: String

    public init(name: String, input: String) {
        self.name = name
        self.input = input
    }
}

public struct AgentToolResult: Codable, Hashable, Sendable {
    public let name: String
    public let output: String
    public let isError: Bool

    public init(name: String, output: String, isError: Bool = false) {
        self.name = name
        self.output = output
        self.isError = isError
    }
}

public struct AgentLoopStep: Codable, Hashable, Sendable {
    public let index: Int
    public let assistantResponse: String
    public let toolCall: AgentToolCall?
    public let toolResult: AgentToolResult?

    public init(
        index: Int,
        assistantResponse: String,
        toolCall: AgentToolCall?,
        toolResult: AgentToolResult?
    ) {
        self.index = index
        self.assistantResponse = assistantResponse
        self.toolCall = toolCall
        self.toolResult = toolResult
    }
}

public struct AgentLoopResult: Codable, Hashable, Sendable {
    public let task: String
    public let finalResponse: String
    public let steps: [AgentLoopStep]
    public let runID: String?

    public init(task: String, finalResponse: String, steps: [AgentLoopStep], runID: String?) {
        self.task = task
        self.finalResponse = finalResponse
        self.steps = steps
        self.runID = runID
    }
}

public enum AgentParsedResponse: Sendable {
    case tool(AgentToolCall)
    case final(String)
}
