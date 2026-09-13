import Foundation

// Portable context-planning value types. Extracted from `ContextPlanningService` (esh iOS M1) so the
// portable core (e.g. Domain/ContextPackage, RunStateStore) can use them without depending on the
// macOS-only context planner (which drives the subprocess-backed ContextQueryEngine).

public struct ContextSnippet: Codable, Hashable, Sendable {
    public let filePath: String
    public let range: SourceRange
    public let lines: [String]
    public let reason: String

    public init(filePath: String, range: SourceRange, lines: [String], reason: String) {
        self.filePath = filePath
        self.range = range
        self.lines = lines
        self.reason = reason
    }
}

public struct ContextPlanningBrief: Codable, Hashable, Sendable {
    public let task: String
    public let summary: String
    public let rankedResults: [RankedContextResult]
    public let snippets: [ContextSnippet]
    public let runSummary: RunSynthesis?
    public let openQuestions: [String]
    public let suggestedNextSteps: [String]

    public init(
        task: String,
        summary: String,
        rankedResults: [RankedContextResult],
        snippets: [ContextSnippet],
        runSummary: RunSynthesis?,
        openQuestions: [String],
        suggestedNextSteps: [String]
    ) {
        self.task = task
        self.summary = summary
        self.rankedResults = rankedResults
        self.snippets = snippets
        self.runSummary = runSummary
        self.openQuestions = openQuestions
        self.suggestedNextSteps = suggestedNextSteps
    }
}
