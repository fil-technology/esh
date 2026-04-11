import Foundation
import EshCore

enum ContextCommand {
    static func run(arguments: [String], currentDirectoryURL: URL) throws {
        let locator = WorkspaceContextLocator()
        let workspaceRootURL = locator.workspaceRootURL(from: currentDirectoryURL)
        let store = ContextStore(locator: locator)
        let runID = CommandSupport.optionalValue(flag: "--run", in: arguments)
        let filteredArguments = CommandSupport.removingKnownFlags(["--run"], from: arguments)

        guard let subcommand = filteredArguments.first else {
            try showStatus(workspaceRootURL: workspaceRootURL, store: store)
            return
        }

        switch subcommand {
        case "build":
            let index = try ContextIndexer().buildIndex(workspaceRootURL: workspaceRootURL)
            try store.save(index: index, workspaceRootURL: workspaceRootURL)
            print("workspace: \(workspaceRootURL.path)")
            print("files: \(index.files.count)")
            print("symbols: \(index.symbols.count)")
            print("edges: \(index.edges.count)")
            print("built_at: \(ISO8601DateFormatter().string(from: index.builtAt))")
        case "status":
            try showStatus(workspaceRootURL: workspaceRootURL, store: store)
        case "query":
            let positional = CommandSupport.positionalArguments(in: Array(filteredArguments.dropFirst()), knownFlags: ["--limit"])
            guard positional.isEmpty == false else {
                throw StoreError.invalidManifest("Usage: esh context query <text> [--limit N] [--run <id>]")
            }
            let limit = Int(CommandSupport.optionalValue(flag: "--limit", in: Array(filteredArguments.dropFirst())) ?? "10") ?? 10
            let index = try store.load(workspaceRootURL: workspaceRootURL)
            let query = positional.joined(separator: " ")
            let results = ContextQueryEngine().query(query, in: index, limit: limit)
            if let runID {
                try? RunStateStore().recordQuery(runID: runID, workspaceRootURL: workspaceRootURL, query: query, results: results)
            }
            if results.isEmpty {
                print("No ranked context results for \"\(query)\".")
                return
            }
            for (offset, result) in results.enumerated() {
                print("\(offset + 1). \(result.filePath)")
                print("   score: \(String(format: "%.1f", result.score))")
                print("   reasons: \(result.reasons.joined(separator: ", "))")
                if result.relatedSymbols.isEmpty == false {
                    print("   symbols: \(result.relatedSymbols.joined(separator: ", "))")
                }
                if let firstRange = result.suggestedRanges.first {
                    print("   range: \(firstRange.lineStart):\(firstRange.lineEnd)")
                }
            }
        case "plan":
            let positional = CommandSupport.positionalArguments(in: Array(filteredArguments.dropFirst()), knownFlags: ["--limit", "--snippets"])
            guard positional.isEmpty == false else {
                throw StoreError.invalidManifest("Usage: esh context plan <task> [--limit N] [--snippets N] [--run <id>]")
            }
            let limit = Int(CommandSupport.optionalValue(flag: "--limit", in: Array(filteredArguments.dropFirst())) ?? "5") ?? 5
            let snippetCount = Int(CommandSupport.optionalValue(flag: "--snippets", in: Array(filteredArguments.dropFirst())) ?? "3") ?? 3
            let index = try store.load(workspaceRootURL: workspaceRootURL)
            let task = positional.joined(separator: " ")
            let runTrace = runID.flatMap { try? RunStateStore().exportTrace(runID: $0, workspaceRootURL: workspaceRootURL) }
            let resolution = try ContextPackageService().resolveBrief(
                task: task,
                index: index,
                workspaceRootURL: workspaceRootURL,
                runTrace: runTrace,
                limit: limit,
                snippetCount: snippetCount
            )
            let brief = resolution.brief
            if let runID {
                try? RunStateStore().recordPlan(runID: runID, workspaceRootURL: workspaceRootURL, task: task, brief: brief)
            }
            print("task: \(brief.task)")
            print("summary: \(brief.summary)")
            print("results: \(brief.rankedResults.count)")
            print("context_package: \(resolution.package.id.uuidString)")
            print("reused_package: \(resolution.reused ? "yes" : "no")")
            if let runSummary = brief.runSummary {
                print("run_status: \(runSummary.status)")
                print("run_summary: \(runSummary.summary)")
                if runSummary.hypotheses.isEmpty == false {
                    print("run_hypotheses: \(runSummary.hypotheses.joined(separator: " | "))")
                }
                if runSummary.findings.isEmpty == false {
                    print("run_findings: \(runSummary.findings.joined(separator: " | "))")
                }
            }
            if brief.rankedResults.isEmpty == false {
                print("top_files:")
                for result in brief.rankedResults.prefix(limit) {
                    print("- \(result.filePath) [\(String(format: "%.1f", result.score))] \(result.reasons.joined(separator: ", "))")
                }
            }
            if brief.snippets.isEmpty == false {
                print("snippets:")
                for snippet in brief.snippets {
                    print("- \(snippet.filePath):\(snippet.range.lineStart):\(snippet.range.lineEnd) | \(snippet.reason)")
                    for (offset, line) in snippet.lines.prefix(8).enumerated() {
                        print("  \(snippet.range.lineStart + offset)\t\(line)")
                    }
                }
            }
            if brief.openQuestions.isEmpty == false {
                print("open_questions:")
                for question in brief.openQuestions {
                    print("- \(question)")
                }
            }
            if brief.suggestedNextSteps.isEmpty == false {
                print("next_steps:")
                for step in brief.suggestedNextSteps {
                    print("- \(step)")
                }
            }
        case "eval":
            let positional = CommandSupport.positionalArguments(in: Array(filteredArguments.dropFirst()), knownFlags: ["--limit"])
            guard let fixturePath = positional.first else {
                throw StoreError.invalidManifest("Usage: esh context eval <fixture.json> [--limit N]")
            }
            let limit = Int(CommandSupport.optionalValue(flag: "--limit", in: Array(filteredArguments.dropFirst())) ?? "5") ?? 5
            let index = try store.load(workspaceRootURL: workspaceRootURL)
            let fixtureURL = URL(fileURLWithPath: fixturePath, relativeTo: currentDirectoryURL).standardizedFileURL
            let data = try Data(contentsOf: fixtureURL)
            let cases = try JSONCoding.decoder.decode([ContextEvaluationCase].self, from: data)
            let report = ContextEvaluationHarness().evaluate(cases: cases, index: index, limit: limit)
            print("cases: \(report.caseCount)")
            print("top1_hits: \(report.top1Hits)")
            print("top3_hits: \(report.top3Hits)")
            print("mrr: \(String(format: "%.3f", report.meanReciprocalRank))")
            for query in report.queries {
                let rank = query.firstRelevantRank.map(String.init) ?? "-"
                let top = query.returnedFiles.prefix(3).joined(separator: ", ")
                print("query: \(query.query)")
                print("  expected: \(query.expectedFiles.joined(separator: ", "))")
                print("  first_relevant_rank: \(rank)")
                print("  top_returned: \(top)")
            }
        default:
            throw StoreError.invalidManifest("Unknown context subcommand: \(subcommand)")
        }
    }

    private static func showStatus(workspaceRootURL: URL, store: ContextStore) throws {
        let status = try store.status(workspaceRootURL: workspaceRootURL)
        print("workspace: \(status.workspaceRootPath)")
        print("built_at: \(ISO8601DateFormatter().string(from: status.builtAt))")
        print("files: \(status.fileCount)")
        print("symbols: \(status.symbolCount)")
        print("edges: \(status.edgeCount)")
    }
}
