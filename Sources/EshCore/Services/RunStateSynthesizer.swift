import Foundation

public struct RunSynthesis: Codable, Hashable, Sendable {
    public let status: String
    public let summary: String
    public let compactedSummary: String?
    public let discoveries: [String]
    public let focusFiles: [String]
    public let focusSymbols: [String]
    public let hypotheses: [String]
    public let findings: [String]
    public let decisions: [String]
    public let openQuestions: [String]
    public let suggestedNextSteps: [String]
    public let transitions: [RunTaskTransition]

    public init(
        status: String,
        summary: String,
        compactedSummary: String?,
        discoveries: [String],
        focusFiles: [String],
        focusSymbols: [String],
        hypotheses: [String],
        findings: [String],
        decisions: [String],
        openQuestions: [String],
        suggestedNextSteps: [String],
        transitions: [RunTaskTransition]
    ) {
        self.status = status
        self.summary = summary
        self.compactedSummary = compactedSummary
        self.discoveries = discoveries
        self.focusFiles = focusFiles
        self.focusSymbols = focusSymbols
        self.hypotheses = hypotheses
        self.findings = findings
        self.decisions = decisions
        self.openQuestions = openQuestions
        self.suggestedNextSteps = suggestedNextSteps
        self.transitions = transitions
    }
}

public struct RunStateSynthesizer: Sendable {
    public init() {}

    public func synthesize(trace: RunTrace) -> RunSynthesis {
        synthesize(state: trace.state, events: trace.events)
    }

    public func synthesize(state: RunState, events: [RunEvent]) -> RunSynthesis {
        let focusFiles = compactedFocusFiles(state: state, events: events)
        let focusSymbols = compactedFocusSymbols(state: state, events: events)
        let discoveries = mergeUnique(
            focusFiles.prefix(3).map { "file: \($0)" },
            with: focusSymbols.prefix(3).map { "symbol: \($0)" }
        )
        let hypotheses = compactedStatements(
            mergeUnique(
            state.hypotheses,
            with: inferredHypotheses(events: events)
            )
        )
        let findings = compactedStatements(
            mergeUnique(
            state.findings,
            with: inferredFindings(events: events)
            )
        )
        let decisions = Array(state.decisions.suffix(5))
        let openQuestions = inferredOpenQuestions(events: events)
        let suggestedNextSteps = inferredNextSteps(state: state, events: events)
        let transitions = taskTransitions(events: events)
        let status = inferredStatus(state: state, events: events)
        let summary = "\(status) run with \(state.discoveredFiles.count) file\(state.discoveredFiles.count == 1 ? "" : "s"), \(state.discoveredSymbols.count) symbol\(state.discoveredSymbols.count == 1 ? "" : "s"), and \(events.count) logged step\(events.count == 1 ? "" : "s")"
        let compactedSummary = makeCompactedSummary(
            status: status,
            focusFiles: focusFiles,
            focusSymbols: focusSymbols,
            findings: findings,
            pendingTasks: state.pendingTasks
        )

        return RunSynthesis(
            status: status,
            summary: summary,
            compactedSummary: compactedSummary,
            discoveries: discoveries,
            focusFiles: Array(focusFiles.prefix(4)),
            focusSymbols: Array(focusSymbols.prefix(4)),
            hypotheses: Array(hypotheses.prefix(4)),
            findings: Array(findings.prefix(4)),
            decisions: decisions,
            openQuestions: openQuestions,
            suggestedNextSteps: suggestedNextSteps,
            transitions: Array(transitions.suffix(5))
        )
    }

    private func inferredHypotheses(events: [RunEvent]) -> [String] {
        var hypotheses: [String] = []

        for event in events.reversed() where event.kind == "context.plan" || event.kind == "context.query" {
            if let topFile = event.attributes?["top_file"], topFile.isEmpty == false {
                hypotheses.append("Relevant area may be \(topFile)")
            }
        }

        return Array(mergeUnique(hypotheses, with: []).prefix(3))
    }

    private func inferredFindings(events: [RunEvent]) -> [String] {
        var findings: [String] = []

        for event in events {
            switch event.kind {
            case "read.symbol":
                if let symbol = event.attributes?["symbol"], let file = event.attributes?["file"] {
                    findings.append("Inspected \(symbol) in \(file)")
                }
            case "read.file":
                if let file = event.attributes?["file"],
                   let lineStart = event.attributes?["line_start"],
                   let lineEnd = event.attributes?["line_end"] {
                    findings.append("Read \(file):\(lineStart)-\(lineEnd)")
                }
            default:
                continue
            }
        }

        return Array(mergeUnique(findings, with: []).suffix(4))
    }

    private func compactedFocusFiles(state: RunState, events: [RunEvent]) -> [String] {
        var ranked: [String] = state.discoveredFiles
        for event in events.reversed() {
            if let file = event.attributes?["file"], file.isEmpty == false {
                ranked.insert(file, at: 0)
            } else if let topFile = event.attributes?["top_file"], topFile.isEmpty == false {
                ranked.insert(topFile, at: 0)
            }
        }
        return compactedStatements(ranked)
    }

    private func compactedFocusSymbols(state: RunState, events: [RunEvent]) -> [String] {
        var ranked: [String] = state.discoveredSymbols
        for event in events.reversed() {
            if let symbol = event.attributes?["symbol"], symbol.isEmpty == false {
                ranked.insert(symbol, at: 0)
            }
        }
        return compactedStatements(ranked)
    }

    private func compactedStatements(_ values: [String]) -> [String] {
        var compacted: [String] = []
        var seen = Set<String>()
        for value in values {
            let normalized = normalizeStatement(value)
            guard seen.contains(normalized) == false else {
                continue
            }
            compacted.append(value)
            seen.insert(normalized)
        }
        return compacted
    }

    private func normalizeStatement(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #" for task: .*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func taskTransitions(events: [RunEvent]) -> [RunTaskTransition] {
        events.compactMap { event in
            switch event.kind {
            case "run.created":
                return RunTaskTransition(timestamp: event.timestamp, phase: "created", detail: event.detail)
            case "context.plan":
                return RunTaskTransition(timestamp: event.timestamp, phase: "planned", detail: event.detail)
            case "run.task.pending":
                return RunTaskTransition(timestamp: event.timestamp, phase: "pending", detail: event.detail)
            case "run.task.completed":
                return RunTaskTransition(timestamp: event.timestamp, phase: "completed", detail: event.detail)
            case "run.status":
                return RunTaskTransition(timestamp: event.timestamp, phase: "status", detail: event.detail)
            default:
                return nil
            }
        }
    }

    private func inferredStatus(state: RunState, events: [RunEvent]) -> String {
        if let explicit = events.reversed().first(where: { $0.kind == "run.status" })?.attributes?["status"],
           explicit.isEmpty == false {
            return explicit
        }
        if state.pendingTasks.isEmpty == false {
            return "in_progress"
        }
        if state.completedTasks.isEmpty == false && state.pendingTasks.isEmpty {
            return "completed"
        }
        if state.status.isEmpty == false {
            return state.status
        }
        return "active"
    }

    private func makeCompactedSummary(
        status: String,
        focusFiles: [String],
        focusSymbols: [String],
        findings: [String],
        pendingTasks: [String]
    ) -> String? {
        guard focusFiles.isEmpty == false || focusSymbols.isEmpty == false || findings.isEmpty == false || pendingTasks.isEmpty == false else {
            return nil
        }

        var parts: [String] = ["\(status) focus"]
        if focusFiles.isEmpty == false {
            parts.append("files: \(focusFiles.prefix(2).joined(separator: ", "))")
        }
        if focusSymbols.isEmpty == false {
            parts.append("symbols: \(focusSymbols.prefix(2).joined(separator: ", "))")
        }
        if findings.isEmpty == false {
            parts.append("findings: \(findings.prefix(1).joined(separator: ", "))")
        }
        if pendingTasks.isEmpty == false {
            parts.append("pending: \(pendingTasks.count)")
        }
        return parts.joined(separator: " | ")
    }

    private func mergeUnique(_ current: [String], with values: [String]) -> [String] {
        var merged = current
        for value in values where merged.contains(value) == false {
            merged.append(value)
        }
        return merged
    }
}
