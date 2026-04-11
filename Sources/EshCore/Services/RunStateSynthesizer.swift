import Foundation

public struct RunSynthesis: Codable, Hashable, Sendable {
    public let summary: String
    public let discoveries: [String]
    public let decisions: [String]
    public let openQuestions: [String]
    public let suggestedNextSteps: [String]

    public init(
        summary: String,
        discoveries: [String],
        decisions: [String],
        openQuestions: [String],
        suggestedNextSteps: [String]
    ) {
        self.summary = summary
        self.discoveries = discoveries
        self.decisions = decisions
        self.openQuestions = openQuestions
        self.suggestedNextSteps = suggestedNextSteps
    }
}

public struct RunStateSynthesizer: Sendable {
    public init() {}

    public func synthesize(trace: RunTrace) -> RunSynthesis {
        synthesize(state: trace.state, events: trace.events)
    }

    public func synthesize(state: RunState, events: [RunEvent]) -> RunSynthesis {
        let discoveries = mergeUnique(
            state.discoveredFiles.prefix(3).map { "file: \($0)" },
            with: state.discoveredSymbols.prefix(3).map { "symbol: \($0)" }
        )
        let decisions = Array(state.decisions.suffix(5))
        let openQuestions = inferredOpenQuestions(events: events)
        let suggestedNextSteps = inferredNextSteps(state: state, events: events)
        let summary = "covered \(state.discoveredFiles.count) file\(state.discoveredFiles.count == 1 ? "" : "s"), \(state.discoveredSymbols.count) symbol\(state.discoveredSymbols.count == 1 ? "" : "s"), and \(events.count) logged step\(events.count == 1 ? "" : "s")"

        return RunSynthesis(
            summary: summary,
            discoveries: discoveries,
            decisions: decisions,
            openQuestions: openQuestions,
            suggestedNextSteps: suggestedNextSteps
        )
    }

    private func inferredOpenQuestions(events: [RunEvent]) -> [String] {
        var questions: [String] = []

        for event in events where event.kind == "context.query" {
            if event.attributes?["result_count"] == "0" {
                questions.append("No ranked results yet for query: \(event.detail)")
            }
        }

        return Array(questions.suffix(3))
    }

    private func inferredNextSteps(state: RunState, events: [RunEvent]) -> [String] {
        var nextSteps = state.pendingTasks

        if nextSteps.isEmpty {
            if let topFile = events.reversed().first(where: { $0.kind == "context.query" })?.attributes?["top_file"],
               topFile.isEmpty == false {
                nextSteps.append("Inspect \(topFile) next")
            }
            if let symbolEvent = events.reversed().first(where: { $0.kind == "read.symbol" }),
               let symbol = symbolEvent.attributes?["symbol"],
               let file = symbolEvent.attributes?["file"] {
                nextSteps.append("Use \(symbol) in \(file) to drive the next change")
            }
        }

        return Array(mergeUnique(nextSteps, with: []).prefix(5))
    }

    private func mergeUnique(_ current: [String], with values: [String]) -> [String] {
        var merged = current
        for value in values where merged.contains(value) == false {
            merged.append(value)
        }
        return merged
    }
}
