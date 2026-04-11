import Foundation

public struct AgentToolService: Sendable {
    private let contextStore: ContextStore
    private let queryEngine: ContextQueryEngine
    private let planningService: ContextPlanningService
    private let readService: ContextReadService
    private let runStateStore: RunStateStore

    public init(
        contextStore: ContextStore = .init(),
        queryEngine: ContextQueryEngine = .init(),
        planningService: ContextPlanningService = .init(),
        readService: ContextReadService = .init(),
        runStateStore: RunStateStore = .init()
    ) {
        self.contextStore = contextStore
        self.queryEngine = queryEngine
        self.planningService = planningService
        self.readService = readService
        self.runStateStore = runStateStore
    }

    public func toolPrompt() -> String {
        """
        Available tools:
        - context_plan: build a ranked local context brief for a task
        - context_query: rank relevant files for a query
        - read_symbol: inspect a symbol definition
        - read_references: inspect references to a symbol
        - read_related: inspect files related to a symbol or path
        - read_file: read a file range. Input format:
          path: relative/path.swift
          start: 1
          end: 80
        - list_files: list workspace files. Input may be blank or a path/text filter.
        - search_text: search workspace text with ripgrep. Input is the search pattern.
        - shell: run a safe workspace command. Allowed:
          swift build
          swift test
          git status --short
          git diff --stat
          git diff -- <path>
          rg <pattern>
          ls [path]

        Respond with exactly one fenced block:
        ```tool
        name: context_plan
        input:
        where is auth refresh handled
        ```
        or
        ```final
        your final answer
        ```
        """
    }

    public func execute(
        call: AgentToolCall,
        workspaceRootURL: URL,
        runID: String?
    ) throws -> AgentToolResult {
        switch call.name {
        case "context_plan":
            return try contextPlan(call.input, workspaceRootURL: workspaceRootURL, runID: runID)
        case "context_query":
            return try contextQuery(call.input, workspaceRootURL: workspaceRootURL, runID: runID)
        case "read_symbol":
            return try readSymbol(call.input, workspaceRootURL: workspaceRootURL, runID: runID)
        case "read_references":
            return try readReferences(call.input, workspaceRootURL: workspaceRootURL, runID: runID)
        case "read_related":
            return try readRelated(call.input, workspaceRootURL: workspaceRootURL, runID: runID)
        case "read_file":
            return try readFile(call.input, workspaceRootURL: workspaceRootURL, runID: runID)
        case "list_files":
            return try listFiles(call.input, workspaceRootURL: workspaceRootURL)
        case "search_text":
            return try searchText(call.input, workspaceRootURL: workspaceRootURL)
        case "shell":
            return try shell(call.input, workspaceRootURL: workspaceRootURL)
        default:
            return AgentToolResult(name: call.name, output: "Unknown tool: \(call.name)", isError: true)
        }
    }

    private func contextPlan(_ task: String, workspaceRootURL: URL, runID: String?) throws -> AgentToolResult {
        let index = try contextStore.load(workspaceRootURL: workspaceRootURL)
        let runTrace = runID.flatMap { try? runStateStore.exportTrace(runID: $0, workspaceRootURL: workspaceRootURL) }
        let brief = try planningService.makeBrief(
            task: task,
            index: index,
            workspaceRootURL: workspaceRootURL,
            runTrace: runTrace,
            limit: 5,
            snippetCount: 2
        )
        if let runID {
            try? runStateStore.recordPlan(runID: runID, workspaceRootURL: workspaceRootURL, task: task, brief: brief)
        }
        var lines = ["summary: \(brief.summary)"]
        if brief.rankedResults.isEmpty == false {
            lines.append("top files:")
            lines.append(contentsOf: brief.rankedResults.prefix(4).map { "- \($0.filePath) [\(String(format: "%.1f", $0.score))]" })
        }
        if brief.openQuestions.isEmpty == false {
            lines.append("open questions: \(brief.openQuestions.prefix(2).joined(separator: " | "))")
        }
        if brief.suggestedNextSteps.isEmpty == false {
            lines.append("next steps: \(brief.suggestedNextSteps.prefix(3).joined(separator: " | "))")
        }
        return AgentToolResult(name: "context_plan", output: lines.joined(separator: "\n"))
    }

    private func contextQuery(_ query: String, workspaceRootURL: URL, runID: String?) throws -> AgentToolResult {
        let index = try contextStore.load(workspaceRootURL: workspaceRootURL)
        let results = queryEngine.query(query, in: index, limit: 5)
        if let runID {
            try? runStateStore.recordQuery(runID: runID, workspaceRootURL: workspaceRootURL, query: query, results: results)
        }
        if results.isEmpty {
            return AgentToolResult(name: "context_query", output: "No ranked context results.")
        }
        let lines = results.map { result in
            let symbols = result.relatedSymbols.isEmpty ? "" : " | symbols: \(result.relatedSymbols.prefix(2).joined(separator: ", "))"
            return "- \(result.filePath) [\(String(format: "%.1f", result.score))]\(symbols)"
        }
        return AgentToolResult(name: "context_query", output: lines.joined(separator: "\n"))
    }

    private func readSymbol(_ symbol: String, workspaceRootURL: URL, runID: String?) throws -> AgentToolResult {
        let index = try contextStore.load(workspaceRootURL: workspaceRootURL)
        let result = try readService.readSymbol(symbol, from: index, workspaceRootURL: workspaceRootURL)
        if let runID {
            try? runStateStore.recordSymbolRead(runID: runID, workspaceRootURL: workspaceRootURL, result: result)
        }
        let lines = result.lines.joined(separator: "\n")
        return AgentToolResult(name: "read_symbol", output: "\(result.symbol.filePath):\(result.range.lineStart)-\(result.range.lineEnd)\n\(lines)")
    }

    private func readReferences(_ symbol: String, workspaceRootURL: URL, runID: String?) throws -> AgentToolResult {
        let index = try contextStore.load(workspaceRootURL: workspaceRootURL)
        let results = try readService.findReferences(symbol, in: index, workspaceRootURL: workspaceRootURL, limit: 10)
        if results.isEmpty {
            return AgentToolResult(name: "read_references", output: "No references found.")
        }
        if let runID {
            for result in results {
                try? runStateStore.recordFileRead(runID: runID, workspaceRootURL: workspaceRootURL, relativePath: relativePath(for: result.fileURL, workspaceRootURL: workspaceRootURL), range: result.range)
            }
        }
        let lines = results.prefix(10).map { "\(relativePath(for: $0.fileURL, workspaceRootURL: workspaceRootURL)):\($0.range.lineStart)-\($0.range.lineEnd) | \($0.lines.prefix(2).joined(separator: " "))" }
        return AgentToolResult(name: "read_references", output: lines.joined(separator: "\n"))
    }

    private func readRelated(_ target: String, workspaceRootURL: URL, runID: String?) throws -> AgentToolResult {
        let index = try contextStore.load(workspaceRootURL: workspaceRootURL)
        let results = try readService.readRelated(target, in: index, workspaceRootURL: workspaceRootURL, limit: 5)
        if results.isEmpty {
            return AgentToolResult(name: "read_related", output: "No related files found.")
        }
        if let runID {
            for result in results {
                try? runStateStore.recordFileRead(runID: runID, workspaceRootURL: workspaceRootURL, relativePath: relativePath(for: result.fileURL, workspaceRootURL: workspaceRootURL), range: result.range)
            }
        }
        let lines = results.map { "\(relativePath(for: $0.fileURL, workspaceRootURL: workspaceRootURL)):\($0.range.lineStart)-\($0.range.lineEnd)\n\($0.lines.prefix(4).joined(separator: "\n"))" }
        return AgentToolResult(name: "read_related", output: lines.joined(separator: "\n\n"))
    }

    private func readFile(_ input: String, workspaceRootURL: URL, runID: String?) throws -> AgentToolResult {
        let parsed = parseReadFileInput(input)
        let result = try readService.readFile(parsed.path, range: parsed.range, workspaceRootURL: workspaceRootURL)
        if let runID {
            try? runStateStore.recordFileRead(runID: runID, workspaceRootURL: workspaceRootURL, relativePath: parsed.path, range: result.range)
        }
        return AgentToolResult(
            name: "read_file",
            output: "\(parsed.path):\(result.range.lineStart)-\(result.range.lineEnd)\n" + result.lines.joined(separator: "\n")
        )
    }

    private func listFiles(_ filter: String, workspaceRootURL: URL) throws -> AgentToolResult {
        let output = try ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["rg", "--files", workspaceRootURL.path]
        )
        let files = String(decoding: output.stdout, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .map { $0.replacingOccurrences(of: workspaceRootURL.path + "/", with: "") }
        let filtered = filter.isEmpty
            ? Array(files.prefix(80))
            : Array(files.filter { $0.localizedCaseInsensitiveContains(filter) }.prefix(80))
        return AgentToolResult(name: "list_files", output: filtered.joined(separator: "\n"))
    }

    private func searchText(_ pattern: String, workspaceRootURL: URL) throws -> AgentToolResult {
        guard pattern.isEmpty == false else {
            return AgentToolResult(name: "search_text", output: "Search pattern must not be empty.", isError: true)
        }
        let output = try ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["rg", "-n", "--no-heading", pattern, workspaceRootURL.path]
        )
        let stdout = String(decoding: output.stdout, as: UTF8.self)
        let stderr = String(decoding: output.stderr, as: UTF8.self)
        let text = stdout.isEmpty ? stderr : stdout
        return AgentToolResult(name: "search_text", output: text.isEmpty ? "No matches." : text)
    }

    private func shell(_ command: String, workspaceRootURL: URL) throws -> AgentToolResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafeShellCommand(trimmed) else {
            return AgentToolResult(name: "shell", output: "Rejected unsafe shell command: \(trimmed)", isError: true)
        }
        let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let executable = tokens.first else {
            return AgentToolResult(name: "shell", output: "Empty shell command.", isError: true)
        }
        let output = try ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [executable] + Array(tokens.dropFirst()),
            currentDirectoryURL: workspaceRootURL
        )
        let stdout = String(decoding: output.stdout, as: UTF8.self)
        let stderr = String(decoding: output.stderr, as: UTF8.self)
        let combined = [stdout, stderr].filter { $0.isEmpty == false }.joined(separator: "\n")
        return AgentToolResult(
            name: "shell",
            output: "exit: \(output.exitCode)\n" + (combined.isEmpty ? "(no output)" : combined),
            isError: output.exitCode != 0
        )
    }

    private func parseReadFileInput(_ input: String) -> (path: String, range: SourceRange) {
        var path = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var start = 1
        var end = 80

        for line in input.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("path:") {
                path = String(trimmed.dropFirst("path:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if trimmed.hasPrefix("start:") {
                start = Int(String(trimmed.dropFirst("start:".count)).trimmingCharacters(in: .whitespacesAndNewlines)) ?? start
            } else if trimmed.hasPrefix("end:") {
                end = Int(String(trimmed.dropFirst("end:".count)).trimmingCharacters(in: .whitespacesAndNewlines)) ?? end
            }
        }

        return (path, SourceRange(lineStart: max(start, 1), lineEnd: max(end, start)))
    }

    private func isSafeShellCommand(_ command: String) -> Bool {
        guard command.isEmpty == false else { return false }
        let forbiddenFragments = ["&&", "||", ";", "|", ">", "<", "`", "$("]
        guard forbiddenFragments.allSatisfy({ command.contains($0) == false }) else {
            return false
        }

        let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = tokens.first else { return false }

        if tokens == ["swift", "build"] || tokens == ["swift", "test"] {
            return true
        }
        if tokens == ["git", "status", "--short"] || tokens == ["git", "diff", "--stat"] {
            return true
        }
        if tokens.count >= 4, tokens[0] == "git", tokens[1] == "diff", tokens[2] == "--" {
            return true
        }
        if first == "rg" || first == "ls" {
            return true
        }

        return false
    }

    private func relativePath(for fileURL: URL, workspaceRootURL: URL) -> String {
        let workspacePath = workspaceRootURL.path.hasSuffix("/") ? workspaceRootURL.path : workspaceRootURL.path + "/"
        if fileURL.path.hasPrefix(workspacePath) {
            return String(fileURL.path.dropFirst(workspacePath.count))
        }
        return fileURL.lastPathComponent
    }
}
