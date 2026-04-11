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
func swiftExtractorCapturesBodyAwareRanges() {
    let source = """
    import Foundation

    struct Planner {
        func makePlan() {
            let steps = ["a", "b"]
            print(steps)
        }
    }
    """

    let result = SymbolExtractor().extractSymbols(
        from: source,
        relativePath: "Sources/Planner.swift",
        language: "swift"
    )

    let planner = result.symbols.first(where: { $0.name == "Planner" })
    let makePlan = result.symbols.first(where: { $0.name == "Planner.makePlan" })

    #expect(planner?.lineStart == 3)
    #expect((planner?.lineEnd ?? 0) >= 7)
    #expect(makePlan?.lineStart == 4)
    #expect((makePlan?.lineEnd ?? 0) >= 6)
}

@Test
func extractorSupportsWebAndContentFiles() {
    let html = """
    <html>
      <head><title>Omnifood Landing</title></head>
      <body>
        <section id="contact" class="section hero">
          <h2>Business Address</h2>
          <a href="/contact.html">Contact</a>
        </section>
      </body>
    </html>
    """
    let css = """
    @import "base.css";
    .section-hero {
      color: red;
    }
    #contact {
      padding: 1rem;
    }
    """
    let json = """
    {
      "name": "omnifood",
      "address": "Jerusalem"
    }
    """
    let markdown = """
    # Getting Started

    See [contact page](./contact.md)
    """

    let extractor = SymbolExtractor()
    let htmlResult = extractor.extractSymbols(from: html, relativePath: "index.html", language: "html")
    let cssResult = extractor.extractSymbols(from: css, relativePath: "styles.css", language: "css")
    let jsonResult = extractor.extractSymbols(from: json, relativePath: "site.json", language: "json")
    let markdownResult = extractor.extractSymbols(from: markdown, relativePath: "README.md", language: "markdown")

    #expect(htmlResult.symbols.contains(where: { $0.name == "#contact" && $0.kind == "id" }))
    #expect(htmlResult.symbols.contains(where: { $0.name == ".hero" && $0.kind == "class" }))
    #expect(htmlResult.symbols.contains(where: { $0.name.contains("business-address") }))
    #expect(htmlResult.imports.contains("/contact.html"))

    #expect(cssResult.symbols.contains(where: { $0.name == ".section-hero" && $0.kind == "selector" }))
    #expect(cssResult.symbols.contains(where: { $0.name == "#contact" && $0.kind == "selector" }))
    #expect(cssResult.imports.contains("base.css"))

    #expect(jsonResult.symbols.contains(where: { $0.name == "name" && $0.kind == "key" }))
    #expect(jsonResult.symbols.contains(where: { $0.name == "address" && $0.kind == "key" }))

    #expect(markdownResult.symbols.contains(where: { $0.name == "h1.getting-started" && $0.kind == "heading" }))
    #expect(markdownResult.imports.contains("./contact.md"))
}

@Test
func indexerIncludesWebsiteFiles() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try """
    <footer class="footer">
      <p>Business Address</p>
    </footer>
    """.write(to: directory.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    try """
    .footer { color: red; }
    """.write(to: directory.appendingPathComponent("styles.css"), atomically: true, encoding: .utf8)
    try """
    { "address": "Jerusalem" }
    """.write(to: directory.appendingPathComponent("site.json"), atomically: true, encoding: .utf8)
    try """
    # Contact
    Business address details.
    """.write(to: directory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

    let index = try ContextIndexer().buildIndex(workspaceRootURL: directory)

    #expect(index.files.count == 4)
    #expect(index.files.contains(where: { $0.path == "index.html" && $0.language == "html" }))
    #expect(index.files.contains(where: { $0.path == "styles.css" && $0.language == "css" }))
    #expect(index.files.contains(where: { $0.path == "site.json" && $0.language == "json" }))
    #expect(index.files.contains(where: { $0.path == "README.md" && $0.language == "markdown" }))
    #expect(index.symbols.contains(where: { $0.filePath == "index.html" }))
    #expect(index.symbols.contains(where: { $0.filePath == "styles.css" }))
    #expect(index.symbols.contains(where: { $0.filePath == "site.json" }))
    #expect(index.symbols.contains(where: { $0.filePath == "README.md" }))
}

@Test
func indexerSkipsAppleAssetCatalogMetadata() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let assetDirectory = directory
        .appendingPathComponent("DemoApp/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
    try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: directory.appendingPathComponent("DemoApp", isDirectory: true),
        withIntermediateDirectories: true
    )

    try """
    import SwiftUI

    struct ContentView: View {
        var body: some View {
            Text("Hello")
        }
    }
    """.write(
        to: directory.appendingPathComponent("DemoApp/ContentView.swift"),
        atomically: true,
        encoding: .utf8
    )
    try """
    {
      "images" : [],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }
    """.write(
        to: assetDirectory.appendingPathComponent("Contents.json"),
        atomically: true,
        encoding: .utf8
    )

    let index = try ContextIndexer().buildIndex(workspaceRootURL: directory)

    #expect(index.files.contains(where: { $0.path == "ContentView.swift" }))
    #expect(index.files.contains(where: { $0.path.hasSuffix("Contents.json") }) == false)
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
func queryEnginePrefersOperationalReadAndChatFiles() {
    let index = ContextIndex(
        workspaceRootPath: "/tmp/demo",
        builtAt: Date(),
        files: [
            FileNode(path: "Sources/esh/Commands/ReadCommand.swift", language: "swift", imports: ["EshCore"], definedSymbols: ["ReadCommand", "ReadCommand.run"], searchTokens: ["read", "symbol", "references", "related", "file", "range"], lastModifiedAt: Date(), contentHash: "a"),
            FileNode(path: "Sources/EshCore/Services/ContextReadService.swift", language: "swift", imports: ["Foundation"], definedSymbols: ["ContextReadService", "ContextReadService.readSymbol", "ContextReadService.findReferences", "ContextReadService.readRelated", "ContextReadService.readFile"], searchTokens: ["read", "symbol", "references", "related", "file", "range"], lastModifiedAt: Date(), contentHash: "b"),
            FileNode(path: "Sources/esh/App/TUIApplication.swift", language: "swift", imports: ["EshCore"], definedSymbols: ["TUIApplication", "TUIApplication.run", "TUIApplication.handleCommand"], searchTokens: ["chat", "session", "autosave", "cache", "intent", "menu", "commands"], lastModifiedAt: Date(), contentHash: "c"),
            FileNode(path: "Sources/EshCore/Persistence/FileCacheStore.swift", language: "swift", imports: ["Foundation"], definedSymbols: ["FileCacheStore"], searchTokens: ["cache", "artifact", "payload", "manifest"], lastModifiedAt: Date(), contentHash: "d")
        ],
        symbols: [
            SymbolNode(name: "ReadCommand", kind: "enum", filePath: "Sources/esh/Commands/ReadCommand.swift", lineStart: 1, lineEnd: 80, containerName: nil),
            SymbolNode(name: "ReadCommand.run", kind: "func", filePath: "Sources/esh/Commands/ReadCommand.swift", lineStart: 2, lineEnd: 70, containerName: "ReadCommand"),
            SymbolNode(name: "ContextReadService", kind: "struct", filePath: "Sources/EshCore/Services/ContextReadService.swift", lineStart: 1, lineEnd: 120, containerName: nil),
            SymbolNode(name: "ContextReadService.readSymbol", kind: "func", filePath: "Sources/EshCore/Services/ContextReadService.swift", lineStart: 5, lineEnd: 20, containerName: "ContextReadService"),
            SymbolNode(name: "ContextReadService.findReferences", kind: "func", filePath: "Sources/EshCore/Services/ContextReadService.swift", lineStart: 22, lineEnd: 48, containerName: "ContextReadService"),
            SymbolNode(name: "ContextReadService.readRelated", kind: "func", filePath: "Sources/EshCore/Services/ContextReadService.swift", lineStart: 50, lineEnd: 75, containerName: "ContextReadService"),
            SymbolNode(name: "ContextReadService.readFile", kind: "func", filePath: "Sources/EshCore/Services/ContextReadService.swift", lineStart: 77, lineEnd: 95, containerName: "ContextReadService"),
            SymbolNode(name: "TUIApplication", kind: "struct", filePath: "Sources/esh/App/TUIApplication.swift", lineStart: 1, lineEnd: 250, containerName: nil),
            SymbolNode(name: "TUIApplication.handleCommand", kind: "func", filePath: "Sources/esh/App/TUIApplication.swift", lineStart: 80, lineEnd: 220, containerName: "TUIApplication")
        ],
        edges: []
    )

    let readResults = ContextQueryEngine().query("read symbol references related file range", in: index, limit: 3)
    #expect(readResults.first?.filePath == "Sources/EshCore/Services/ContextReadService.swift")
    #expect(readResults.prefix(2).contains(where: { $0.filePath == "Sources/esh/Commands/ReadCommand.swift" }))

    let chatResults = ContextQueryEngine().query("chat session autosave cache intent menu commands", in: index, limit: 3)
    #expect(chatResults.first?.filePath == "Sources/esh/App/TUIApplication.swift")
}

@Test
func queryEnginePrefersSwiftUIBehaviorFilesOverGenericModels() {
    let index = ContextIndex(
        workspaceRootPath: "/tmp/demo",
        builtAt: Date(),
        files: [
            FileNode(path: "SimpleToDo/ContentView.swift", language: "swift", imports: ["SwiftUI"], definedSymbols: ["ContentView"], searchTokens: ["toolbar", "button", "add", "label", "navigation", "list"], lastModifiedAt: Date(), contentHash: "a"),
            FileNode(path: "SimpleToDo/ViewModel.swift", language: "swift", imports: ["Foundation"], definedSymbols: ["ViewModel", "ViewModel.add"], searchTokens: ["items", "add", "delete", "save"], lastModifiedAt: Date(), contentHash: "b"),
            FileNode(path: "SimpleToDo/ItemRow.swift", language: "swift", imports: ["SwiftUI"], definedSymbols: ["ItemRow"], searchTokens: ["label", "accessibility", "value", "navigation"], lastModifiedAt: Date(), contentHash: "c"),
            FileNode(path: "SimpleToDo/ToDoItem.swift", language: "swift", imports: ["Foundation"], definedSymbols: ["ToDoItem", "ToDoItem.accessibilityValue"], searchTokens: ["accessibility", "value", "complete", "priority"], lastModifiedAt: Date(), contentHash: "d")
        ],
        symbols: [
            SymbolNode(name: "ContentView", kind: "struct", filePath: "SimpleToDo/ContentView.swift", lineStart: 1, lineEnd: 60, containerName: nil),
            SymbolNode(name: "ViewModel", kind: "class", filePath: "SimpleToDo/ViewModel.swift", lineStart: 1, lineEnd: 70, containerName: nil),
            SymbolNode(name: "ViewModel.add", kind: "func", filePath: "SimpleToDo/ViewModel.swift", lineStart: 40, lineEnd: 50, containerName: "ViewModel"),
            SymbolNode(name: "ItemRow", kind: "struct", filePath: "SimpleToDo/ItemRow.swift", lineStart: 1, lineEnd: 40, containerName: nil),
            SymbolNode(name: "ToDoItem", kind: "struct", filePath: "SimpleToDo/ToDoItem.swift", lineStart: 1, lineEnd: 80, containerName: nil),
            SymbolNode(name: "ToDoItem.accessibilityValue", kind: "func", filePath: "SimpleToDo/ToDoItem.swift", lineStart: 40, lineEnd: 60, containerName: "ToDoItem")
        ],
        edges: []
    )

    let addButton = ContextQueryEngine().query("where is add item button implemented", in: index, limit: 4)
    #expect(addButton.first?.filePath == "SimpleToDo/ContentView.swift")

    let accessibility = ContextQueryEngine().query("add item accessibility label location file", in: index, limit: 4)
    #expect(accessibility.first?.filePath != "SimpleToDo/Assets.xcassets/AppIcon.appiconset/Contents.json")
    #expect(accessibility.prefix(3).contains(where: { $0.filePath == "SimpleToDo/ItemRow.swift" }))
    #expect(accessibility.prefix(3).contains(where: { $0.filePath == "SimpleToDo/ToDoItem.swift" }))
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

@Test
func contextPackageServiceReusesValidPackages() throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
    let sourceURL = workspaceURL.appendingPathComponent("Sources/Auth/TokenManager.swift")
    try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try """
    struct TokenManager {
        func refreshIfNeeded() {
            print("refresh")
        }
    }
    """.write(to: sourceURL, atomically: true, encoding: .utf8)

    let index = try ContextIndexer().buildIndex(workspaceRootURL: workspaceURL)
    let service = ContextPackageService(store: FileContextPackageStore(root: PersistenceRoot(rootURL: rootURL)))

    let first = try service.resolveBrief(
        task: "refresh auth token",
        index: index,
        workspaceRootURL: workspaceURL,
        limit: 3,
        snippetCount: 2,
        modelID: "demo-model",
        intent: .code,
        cacheMode: .triattention
    )
    let second = try service.resolveBrief(
        task: "refresh auth token",
        index: index,
        workspaceRootURL: workspaceURL,
        limit: 3,
        snippetCount: 2,
        modelID: "demo-model",
        intent: .code,
        cacheMode: .triattention
    )

    #expect(first.reused == false)
    #expect(second.reused == true)
    #expect(first.package.id == second.package.id)
}

@Test
func contextPackageServiceInvalidatesChangedFiles() throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
    let sourceURL = workspaceURL.appendingPathComponent("Sources/Auth/TokenManager.swift")
    try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try """
    struct TokenManager {
        func refreshIfNeeded() {
            print("refresh")
        }
    }
    """.write(to: sourceURL, atomically: true, encoding: .utf8)

    let store = FileContextPackageStore(root: PersistenceRoot(rootURL: rootURL))
    let service = ContextPackageService(store: store)
    let firstIndex = try ContextIndexer().buildIndex(workspaceRootURL: workspaceURL)
    let first = try service.resolveBrief(
        task: "refresh auth token",
        index: firstIndex,
        workspaceRootURL: workspaceURL,
        limit: 3,
        snippetCount: 2
    )

    try """
    struct TokenManager {
        func refreshIfNeeded() {
            print("refresh now")
        }
    }
    """.write(to: sourceURL, atomically: true, encoding: .utf8)
    let secondIndex = try ContextIndexer().buildIndex(workspaceRootURL: workspaceURL)
    let second = try service.resolveBrief(
        task: "refresh auth token",
        index: secondIndex,
        workspaceRootURL: workspaceURL,
        limit: 3,
        snippetCount: 2
    )

    #expect(first.reused == false)
    #expect(second.reused == false)
    #expect(first.package.id != second.package.id)
}
