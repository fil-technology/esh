import Foundation

public struct RunStateStore: Sendable {
    private let root: PersistenceRoot
    private static let eventEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public init(root: PersistenceRoot = .default()) {
        self.root = root
    }

    public func createRun(workspaceRootURL: URL, name: String? = nil) throws -> RunState {
        let runID = name?.isEmpty == false ? sanitize(name!) + "-" + shortRandomID() : shortRandomID()
        let state = RunState(runID: runID, workspaceRootPath: workspaceRootURL.path)
        try save(state: state)
        try append(
            event: RunEvent(
                runID: runID,
                kind: "run.created",
                detail: workspaceRootURL.path,
                attributes: ["workspace": workspaceRootURL.path]
            ),
            workspaceRootURL: workspaceRootURL
        )
        return state
    }

    public func load(runID: String, workspaceRootURL: URL) throws -> RunState {
        let url = runStateURL(runID: runID, workspaceRootURL: workspaceRootURL)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StoreError.notFound("Run \(runID) was not found for \(workspaceRootURL.path).")
        }
        return try JSONCoding.decoder.decode(RunState.self, from: Data(contentsOf: url))
    }

    public func save(state: RunState) throws {
        let workspaceRootURL = URL(fileURLWithPath: state.workspaceRootPath, isDirectory: true)
        try ensureDirectory(workspaceRootURL: workspaceRootURL)
        try JSONCoding.encoder.encode(state).write(to: runStateURL(runID: state.runID, workspaceRootURL: workspaceRootURL), options: .atomic)
    }

    public func recordQuery(runID: String, workspaceRootURL: URL, query: String, results: [RankedContextResult]) throws {
        var state = try load(runID: runID, workspaceRootURL: workspaceRootURL)
        state.discoveredFiles = mergeUnique(state.discoveredFiles, with: results.map(\.filePath))
        state.discoveredSymbols = mergeUnique(state.discoveredSymbols, with: results.flatMap(\.relatedSymbols))
        state.decisions = mergeUnique(state.decisions, with: ["query: \(query)"])
        state.updatedAt = Date()
        try save(state: state)
        try append(
            event: RunEvent(
                runID: runID,
                kind: "context.query",
                detail: query,
                attributes: [
                    "query": query,
                    "result_count": String(results.count),
                    "top_file": results.first?.filePath ?? ""
                ]
            ),
            workspaceRootURL: workspaceRootURL
        )
    }

    public func recordSymbolRead(runID: String, workspaceRootURL: URL, result: SymbolReadResult) throws {
        var state = try load(runID: runID, workspaceRootURL: workspaceRootURL)
        state.discoveredFiles = mergeUnique(state.discoveredFiles, with: [result.symbol.filePath])
        state.discoveredSymbols = mergeUnique(state.discoveredSymbols, with: [result.symbol.name])
        state.updatedAt = Date()
        try save(state: state)
        try append(
            event: RunEvent(
                runID: runID,
                kind: "read.symbol",
                detail: result.symbol.name,
                attributes: [
                    "symbol": result.symbol.name,
                    "file": result.symbol.filePath,
                    "line_start": String(result.symbol.lineStart),
                    "line_end": String(result.symbol.lineEnd)
                ]
            ),
            workspaceRootURL: workspaceRootURL
        )
    }

    public func recordFileRead(runID: String, workspaceRootURL: URL, relativePath: String, range: SourceRange) throws {
        var state = try load(runID: runID, workspaceRootURL: workspaceRootURL)
        state.discoveredFiles = mergeUnique(state.discoveredFiles, with: [relativePath])
        state.updatedAt = Date()
        try save(state: state)
        try append(
            event: RunEvent(
                runID: runID,
                kind: "read.file",
                detail: "\(relativePath):\(range.lineStart):\(range.lineEnd)",
                attributes: [
                    "file": relativePath,
                    "line_start": String(range.lineStart),
                    "line_end": String(range.lineEnd)
                ]
            ),
            workspaceRootURL: workspaceRootURL
        )
    }

    public func recordPlan(runID: String, workspaceRootURL: URL, task: String, brief: ContextPlanningBrief) throws {
        var state = try load(runID: runID, workspaceRootURL: workspaceRootURL)
        state.discoveredFiles = mergeUnique(state.discoveredFiles, with: brief.rankedResults.map(\.filePath))
        state.discoveredSymbols = mergeUnique(state.discoveredSymbols, with: brief.rankedResults.flatMap(\.relatedSymbols))
        if let topFile = brief.rankedResults.first?.filePath {
            state.hypotheses = mergeUnique(state.hypotheses, with: ["Relevant area may be \(topFile) for task: \(task)"])
        }
        state.decisions = mergeUnique(state.decisions, with: ["plan: \(task)"])
        state.pendingTasks = mergeUnique(state.pendingTasks, with: brief.suggestedNextSteps)
        state.updatedAt = Date()
        try save(state: state)
        try append(
            event: RunEvent(
                runID: runID,
                kind: "context.plan",
                detail: task,
                attributes: [
                    "task": task,
                    "top_file": brief.rankedResults.first?.filePath ?? "",
                    "result_count": String(brief.rankedResults.count),
                    "snippet_count": String(brief.snippets.count),
                    "open_question_count": String(brief.openQuestions.count)
                ]
            ),
            workspaceRootURL: workspaceRootURL
        )
    }

    public func recordHypothesis(runID: String, workspaceRootURL: URL, text: String) throws {
        try recordReasoningItem(
            runID: runID,
            workspaceRootURL: workspaceRootURL,
            text: text,
            kind: "run.hypothesis",
            mutate: { state in state.hypotheses = mergeUnique(state.hypotheses, with: [text]) }
        )
    }

    public func recordFinding(runID: String, workspaceRootURL: URL, text: String) throws {
        try recordReasoningItem(
            runID: runID,
            workspaceRootURL: workspaceRootURL,
            text: text,
            kind: "run.finding",
            mutate: { state in state.findings = mergeUnique(state.findings, with: [text]) }
        )
    }

    public func recordDecision(runID: String, workspaceRootURL: URL, text: String) throws {
        try recordReasoningItem(
            runID: runID,
            workspaceRootURL: workspaceRootURL,
            text: text,
            kind: "run.decision",
            mutate: { state in state.decisions = mergeUnique(state.decisions, with: [text]) }
        )
    }

    public func recordPendingTask(runID: String, workspaceRootURL: URL, text: String) throws {
        try recordReasoningItem(
            runID: runID,
            workspaceRootURL: workspaceRootURL,
            text: text,
            kind: "run.task.pending",
            mutate: { state in state.pendingTasks = mergeUnique(state.pendingTasks, with: [text]) }
        )
    }

    public func recordCompletedTask(runID: String, workspaceRootURL: URL, text: String) throws {
        try recordReasoningItem(
            runID: runID,
            workspaceRootURL: workspaceRootURL,
            text: text,
            kind: "run.task.completed",
            mutate: { state in
                state.pendingTasks.removeAll { $0 == text }
                state.completedTasks = mergeUnique(state.completedTasks, with: [text])
            }
        )
    }

    public func updateStatus(runID: String, workspaceRootURL: URL, status: String) throws {
        var state = try load(runID: runID, workspaceRootURL: workspaceRootURL)
        state.status = status
        state.updatedAt = Date()
        try save(state: state)
        try append(
            event: RunEvent(
                runID: runID,
                kind: "run.status",
                detail: status,
                attributes: ["status": status]
            ),
            workspaceRootURL: workspaceRootURL
        )
    }

    public func exportTrace(runID: String, workspaceRootURL: URL) throws -> RunTrace {
        let state = try load(runID: runID, workspaceRootURL: workspaceRootURL)
        let events = try loadEvents(runID: runID, workspaceRootURL: workspaceRootURL)
        return RunTrace(state: state, events: events)
    }

    public func loadEvents(runID: String, workspaceRootURL: URL) throws -> [RunEvent] {
        let url = eventLogURL(workspaceRootURL: workspaceRootURL)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        return try lines.compactMap { line in
            let event = try JSONCoding.decoder.decode(RunEvent.self, from: Data(line.utf8))
            return event.runID == runID ? event : nil
        }
    }

    private func append(event: RunEvent, workspaceRootURL: URL) throws {
        try ensureDirectory(workspaceRootURL: workspaceRootURL)
        let url = eventLogURL(workspaceRootURL: workspaceRootURL)
        let data = try Self.eventEncoder.encode(event) + Data([0x0A])
        if FileManager.default.fileExists(atPath: url.path) {
            var combined = try Data(contentsOf: url)
            combined.append(data)
            try combined.write(to: url, options: .atomic)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    private func ensureDirectory(workspaceRootURL: URL) throws {
        try FileManager.default.createDirectory(at: directoryURL(workspaceRootURL: workspaceRootURL), withIntermediateDirectories: true)
    }

    private func directoryURL(workspaceRootURL: URL) -> URL {
        root.rootURL
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(Fingerprint.sha256([workspaceRootURL.path]), isDirectory: true)
    }

    private func runStateURL(runID: String, workspaceRootURL: URL) -> URL {
        directoryURL(workspaceRootURL: workspaceRootURL).appendingPathComponent("\(runID).json")
    }

    private func eventLogURL(workspaceRootURL: URL) -> URL {
        directoryURL(workspaceRootURL: workspaceRootURL).appendingPathComponent("events.jsonl")
    }

    private func sanitize(_ value: String) -> String {
        let allowed = value.lowercased().map { character -> Character in
            switch character {
            case "a"..."z", "0"..."9":
                return character
            default:
                return "-"
            }
        }
        return String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func shortRandomID() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }

    private func recordReasoningItem(
        runID: String,
        workspaceRootURL: URL,
        text: String,
        kind: String,
        mutate: (inout RunState) -> Void
    ) throws {
        var state = try load(runID: runID, workspaceRootURL: workspaceRootURL)
        mutate(&state)
        state.updatedAt = Date()
        try save(state: state)
        try append(
            event: RunEvent(
                runID: runID,
                kind: kind,
                detail: text,
                attributes: ["text": text]
            ),
            workspaceRootURL: workspaceRootURL
        )
    }

    private func mergeUnique(_ current: [String], with values: [String]) -> [String] {
        var merged = current
        for value in values where merged.contains(value) == false {
            merged.append(value)
        }
        return merged
    }
}
