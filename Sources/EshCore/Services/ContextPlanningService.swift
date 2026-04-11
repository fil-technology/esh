import Foundation

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

public struct ContextPlanningService: Sendable {
    private let queryEngine: ContextQueryEngine
    private let readService: ContextReadService
    private let synthesizer: RunStateSynthesizer

    public init(
        queryEngine: ContextQueryEngine = .init(),
        readService: ContextReadService = .init(),
        synthesizer: RunStateSynthesizer = .init()
    ) {
        self.queryEngine = queryEngine
        self.readService = readService
        self.synthesizer = synthesizer
    }

    public func makeBrief(
        task: String,
        index: ContextIndex,
        workspaceRootURL: URL,
        runTrace: RunTrace? = nil,
        limit: Int = 5,
        snippetCount: Int = 3
    ) throws -> ContextPlanningBrief {
        let rankedResults = queryEngine.query(task, in: index, limit: limit)
        let snippets = rankedResults.prefix(snippetCount).compactMap { result -> ContextSnippet? in
            let range = result.suggestedRanges.first ?? SourceRange(lineStart: 1, lineEnd: 40)
            guard let read = try? readService.readFile(result.filePath, range: range, workspaceRootURL: workspaceRootURL) else {
                return nil
            }
            return ContextSnippet(
                filePath: result.filePath,
                range: read.range,
                lines: read.lines,
                reason: result.reasons.first ?? "ranked context"
            )
        }

        return buildBrief(
            task: task,
            rankedResults: rankedResults,
            snippets: snippets,
            runTrace: runTrace
        )
    }

    public func refreshBrief(_ brief: ContextPlanningBrief, runTrace: RunTrace?) -> ContextPlanningBrief {
        buildBrief(
            task: brief.task,
            rankedResults: brief.rankedResults,
            snippets: brief.snippets,
            runTrace: runTrace
        )
    }

    private func buildBrief(
        task: String,
        rankedResults: [RankedContextResult],
        snippets: [ContextSnippet],
        runTrace: RunTrace?
    ) -> ContextPlanningBrief {
        let runSummary = runTrace.map { synthesizer.synthesize(trace: $0) }
        let openQuestions = mergeUnique(
            rankedResults.isEmpty ? ["No ranked context matched the task yet. Rebuild the index or broaden the query."] : [],
            with: inferredOpenQuestions(from: rankedResults, runSummary: runSummary)
        )
        let suggestedNextSteps = suggestedSteps(
            task: task,
            rankedResults: rankedResults,
            snippets: snippets,
            runSummary: runSummary
        )
        let summary = makeSummary(
            task: task,
            rankedResults: rankedResults,
            snippets: snippets,
            runSummary: runSummary
        )

        return ContextPlanningBrief(
            task: task,
            summary: summary,
            rankedResults: rankedResults,
            snippets: snippets,
            runSummary: runSummary,
            openQuestions: openQuestions,
            suggestedNextSteps: suggestedNextSteps
        )
    }

    public func augmentedPrompt(userPrompt: String, brief: ContextPlanningBrief) -> String {
        guard brief.rankedResults.isEmpty == false || brief.snippets.isEmpty == false || brief.runSummary != nil else {
            return userPrompt
        }

        var lines = [userPrompt, "", "[Local context brief]"]
        lines.append("Task: \(brief.task)")
        lines.append("Summary: \(brief.summary)")

        if let runSummary = brief.runSummary {
            lines.append("Previous run summary: \(runSummary.summary)")
            if let compacted = runSummary.compactedSummary {
                lines.append("Compacted run state: \(compacted)")
            }
            lines.append("Run status: \(runSummary.status)")
            if runSummary.discoveries.isEmpty == false {
                lines.append("Already learned: \(runSummary.discoveries.prefix(3).joined(separator: "; "))")
            }
            if runSummary.hypotheses.isEmpty == false {
                lines.append("Working hypotheses: \(runSummary.hypotheses.prefix(2).joined(separator: " | "))")
            }
            if runSummary.findings.isEmpty == false {
                lines.append("Findings so far: \(runSummary.findings.prefix(2).joined(separator: " | "))")
            }
        }

        if brief.rankedResults.isEmpty == false {
            lines.append("Top files:")
            lines.append(contentsOf: brief.rankedResults.prefix(3).map {
                "- \($0.filePath) [\(String(format: "%.1f", $0.score))] \($0.reasons.prefix(2).joined(separator: ", "))"
            })
        }

        if brief.snippets.isEmpty == false {
            lines.append("Surgical reads:")
            lines.append(contentsOf: brief.snippets.prefix(2).map { snippet in
                let preview = snippet.lines.prefix(6).joined(separator: "\n")
                return """
                - \(snippet.filePath):\(snippet.range.lineStart)-\(snippet.range.lineEnd) (\(snippet.reason))
                \(preview)
                """
            })
        }

        if brief.openQuestions.isEmpty == false {
            lines.append("Open questions: \(brief.openQuestions.prefix(2).joined(separator: " | "))")
        }

        lines.append("[/Local context brief]")
        return lines.joined(separator: "\n")
    }

    private func makeSummary(
        task: String,
        rankedResults: [RankedContextResult],
        snippets: [ContextSnippet],
        runSummary: RunSynthesis?
    ) -> String {
        if rankedResults.isEmpty {
            return runSummary.map { "No direct ranked hits; existing run knowledge says \($0.summary.lowercased())" }
                ?? "No direct ranked hits yet for the current task."
        }

        let primary = rankedResults.prefix(2).map(\.filePath).joined(separator: ", ")
        let snippetSummary = snippets.isEmpty ? "without surgical reads yet" : "with \(snippets.count) surgical read\(snippets.count == 1 ? "" : "s")"
        if let runSummary {
            return "Likely starting points are \(primary), \(snippetSummary); previous run context says \(runSummary.summary.lowercased())"
        }
        return "Likely starting points are \(primary), \(snippetSummary)."
    }

    private func inferredOpenQuestions(
        from rankedResults: [RankedContextResult],
        runSummary: RunSynthesis?
    ) -> [String] {
        var questions: [String] = []

        if rankedResults.allSatisfy({ $0.relatedSymbols.isEmpty }) && rankedResults.isEmpty == false {
            questions.append("Top matches are mostly file-level; symbol-level disambiguation is still weak.")
        }

        if let runSummary {
            questions = mergeUnique(questions, with: runSummary.openQuestions)
        }

        return questions
    }

    private func suggestedSteps(
        task: String,
        rankedResults: [RankedContextResult],
        snippets: [ContextSnippet],
        runSummary: RunSynthesis?
    ) -> [String] {
        var steps: [String] = []

        for result in rankedResults.prefix(3) {
            if let symbol = result.relatedSymbols.first {
                steps.append("Inspect \(symbol) in \(result.filePath)")
            } else {
                steps.append("Inspect \(result.filePath)")
            }
        }

        for snippet in snippets.prefix(2) {
            steps.append("Use \(snippet.filePath):\(snippet.range.lineStart)-\(snippet.range.lineEnd) while planning the next edit")
        }

        if let runSummary {
            steps = mergeUnique(steps, with: runSummary.suggestedNextSteps)
        }

        if steps.isEmpty {
            steps.append("Broaden the task description for \(task) and rerun context planning")
        }

        return Array(steps.prefix(5))
    }

    private func mergeUnique(_ current: [String], with values: [String]) -> [String] {
        var merged = current
        for value in values where merged.contains(value) == false {
            merged.append(value)
        }
        return merged
    }
}
