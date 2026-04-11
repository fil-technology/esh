import Foundation
import Testing
@testable import EshCore

@Test
func swiftExtractorFindsImportsAndSymbols() {
    let source = """
    import Foundation

    struct ContextStore {
        func loadIndex() {}
    }
    """

    let result = SymbolExtractor().extractSymbols(
        from: source,
        relativePath: "Sources/ContextStore.swift",
        language: "swift"
    )

    #expect(result.imports == ["Foundation"])
    #expect(result.symbols.contains(where: { $0.name == "ContextStore" && $0.kind == "struct" }))
    #expect(result.symbols.contains(where: { $0.name == "ContextStore.loadIndex" && $0.kind == "func" }))
}

@Test
func queryEngineBoostsFileAndSymbolMatches() {
    let index = ContextIndex(
        workspaceRootPath: "/tmp/demo",
        builtAt: Date(),
        files: [
            FileNode(path: "Sources/Auth/TokenManager.swift", language: "swift", imports: [], definedSymbols: ["TokenManager", "TokenManager.refreshIfNeeded"], lastModifiedAt: Date(), contentHash: "a"),
            FileNode(path: "Sources/UI/HeaderBarView.swift", language: "swift", imports: [], definedSymbols: ["HeaderBarView"], lastModifiedAt: Date.distantPast, contentHash: "b")
        ],
        symbols: [
            SymbolNode(name: "TokenManager", kind: "class", filePath: "Sources/Auth/TokenManager.swift", lineStart: 1, lineEnd: 20, containerName: nil),
            SymbolNode(name: "TokenManager.refreshIfNeeded", kind: "func", filePath: "Sources/Auth/TokenManager.swift", lineStart: 10, lineEnd: 18, containerName: "TokenManager"),
            SymbolNode(name: "HeaderBarView", kind: "struct", filePath: "Sources/UI/HeaderBarView.swift", lineStart: 1, lineEnd: 20, containerName: nil)
        ],
        edges: []
    )

    let results = ContextQueryEngine().query("refresh token auth", in: index, limit: 5)

    #expect(results.first?.filePath == "Sources/Auth/TokenManager.swift")
    #expect(results.first?.relatedSymbols.contains("TokenManager.refreshIfNeeded") == true)
}

@Test
func readServiceReturnsRequestedRange() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("Demo.swift")
    try """
    line1
    line2
    line3
    line4
    """.write(to: fileURL, atomically: true, encoding: .utf8)

    let result = try ContextReadService().readFile(
        "Demo.swift",
        range: SourceRange(lineStart: 2, lineEnd: 3),
        workspaceRootURL: directory
    )

    #expect(result.lines == ["line2", "line3"])
}

@Test
func readServiceFindsReferences() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try """
    struct TokenManager {}
    func refreshIfNeeded() {
        let manager = TokenManager()
        _ = manager
    }
    """.write(to: directory.appendingPathComponent("Token.swift"), atomically: true, encoding: .utf8)

    let index = ContextIndex(
        workspaceRootPath: directory.path,
        builtAt: Date(),
        files: [FileNode(path: "Token.swift", language: "swift", imports: [], definedSymbols: [], lastModifiedAt: Date(), contentHash: "x")],
        symbols: [],
        edges: []
    )

    let results = try ContextReadService().findReferences("TokenManager", in: index, workspaceRootURL: directory, limit: 10)

    #expect(results.isEmpty == false)
}

@Test
func runStateStorePersistsEvents() throws {
    let rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    let workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

    let store = RunStateStore(root: PersistenceRoot(rootURL: rootURL))
    let state = try store.createRun(workspaceRootURL: workspaceURL, name: "demo")
    let ranked = [
        RankedContextResult(filePath: "Sources/Auth.swift", score: 10, reasons: ["symbol match"], suggestedRanges: [], relatedSymbols: ["AuthManager.refresh"])
    ]

    try store.recordQuery(runID: state.runID, workspaceRootURL: workspaceURL, query: "refresh auth", results: ranked)
    let loaded = try store.load(runID: state.runID, workspaceRootURL: workspaceURL)
    let events = try store.loadEvents(runID: state.runID, workspaceRootURL: workspaceURL)

    #expect(loaded.discoveredFiles.contains("Sources/Auth.swift"))
    #expect(loaded.discoveredSymbols.contains("AuthManager.refresh"))
    #expect(events.contains(where: { $0.kind == "context.query" }))
    #expect(events.first(where: { $0.kind == "context.query" })?.attributes?["result_count"] == "1")
}

@Test
func runStateStoreExportsTrace() throws {
    let rootURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    let workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

    let store = RunStateStore(root: PersistenceRoot(rootURL: rootURL))
    let state = try store.createRun(workspaceRootURL: workspaceURL, name: "demo")
    try store.recordFileRead(
        runID: state.runID,
        workspaceRootURL: workspaceURL,
        relativePath: "Sources/Demo.swift",
        range: SourceRange(lineStart: 4, lineEnd: 9)
    )

    let trace = try store.exportTrace(runID: state.runID, workspaceRootURL: workspaceURL)

    #expect(trace.state.runID == state.runID)
    #expect(trace.events.contains(where: { $0.kind == "read.file" && $0.attributes?["file"] == "Sources/Demo.swift" }))
}

@Test
func planningServiceBuildsBriefWithSnippetsAndSuggestions() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let sourceURL = directory.appendingPathComponent("Sources/Auth/TokenManager.swift")
    try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try """
    struct TokenManager {
        func refreshIfNeeded() {
            print("refresh")
        }
    }
    """.write(to: sourceURL, atomically: true, encoding: .utf8)

    let index = try ContextIndexer().buildIndex(workspaceRootURL: directory)
    let brief = try ContextPlanningService().makeBrief(
        task: "refresh auth token",
        index: index,
        workspaceRootURL: directory,
        limit: 3,
        snippetCount: 2
    )

    #expect(brief.rankedResults.first?.filePath.hasSuffix("TokenManager.swift") == true)
    #expect(brief.snippets.isEmpty == false)
    #expect(brief.suggestedNextSteps.isEmpty == false)
}

@Test
func runStateSynthesizerProducesSummaryAndNextStepHints() throws {
    let state = RunState(
        runID: "demo",
        workspaceRootPath: "/tmp/demo",
        discoveredFiles: ["Sources/Auth.swift"],
        discoveredSymbols: ["AuthManager.refresh"],
        decisions: ["plan: refresh auth"],
        pendingTasks: []
    )
    let events = [
        RunEvent(runID: "demo", kind: "context.query", detail: "refresh auth", attributes: ["result_count": "1", "top_file": "Sources/Auth.swift"]),
        RunEvent(runID: "demo", kind: "read.symbol", detail: "AuthManager.refresh", attributes: ["symbol": "AuthManager.refresh", "file": "Sources/Auth.swift"])
    ]

    let synthesis = RunStateSynthesizer().synthesize(state: state, events: events)

    #expect(synthesis.summary.contains("covered 1 file"))
    #expect(synthesis.discoveries.contains("file: Sources/Auth.swift"))
    #expect(synthesis.suggestedNextSteps.contains(where: { $0.contains("Sources/Auth.swift") }))
}

@Test
func evaluationHarnessComputesRetrievalMetrics() {
    let index = ContextIndex(
        workspaceRootPath: "/tmp/demo",
        builtAt: Date(),
        files: [
            FileNode(path: "Sources/Auth/TokenManager.swift", language: "swift", imports: [], definedSymbols: ["TokenManager", "TokenManager.refreshIfNeeded"], lastModifiedAt: Date(), contentHash: "a"),
            FileNode(path: "Sources/UI/HeaderBarView.swift", language: "swift", imports: [], definedSymbols: ["HeaderBarView"], lastModifiedAt: Date(), contentHash: "b")
        ],
        symbols: [
            SymbolNode(name: "TokenManager", kind: "class", filePath: "Sources/Auth/TokenManager.swift", lineStart: 1, lineEnd: 20, containerName: nil),
            SymbolNode(name: "TokenManager.refreshIfNeeded", kind: "func", filePath: "Sources/Auth/TokenManager.swift", lineStart: 10, lineEnd: 18, containerName: "TokenManager"),
            SymbolNode(name: "HeaderBarView", kind: "struct", filePath: "Sources/UI/HeaderBarView.swift", lineStart: 1, lineEnd: 20, containerName: nil)
        ],
        edges: []
    )
    let report = ContextEvaluationHarness().evaluate(
        cases: [
            ContextEvaluationCase(query: "refresh token auth", expectedFiles: ["Sources/Auth/TokenManager.swift"]),
            ContextEvaluationCase(query: "header ui", expectedFiles: ["Sources/UI/HeaderBarView.swift"])
        ],
        index: index,
        limit: 3
    )

    #expect(report.caseCount == 2)
    #expect(report.top1Hits == 2)
    #expect(report.top3Hits == 2)
    #expect(report.meanReciprocalRank == 1)
}
