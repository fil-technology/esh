import Foundation
import Testing
@testable import EshCore

@Test
func agentResponseParserParsesToolBlock() {
    let parsed = AgentResponseParser().parse(
        """
        ```tool
        name: context_query
        input:
        auth refresh token
        ```
        """
    )

    guard case let .tool(call)? = parsed else {
        Issue.record("Expected tool call")
        return
    }

    #expect(call.name == "context_query")
    #expect(call.input == "auth refresh token")
}

@Test
func agentResponseParserParsesFinalBlock() {
    let parsed = AgentResponseParser().parse(
        """
        ```final
        Auth refresh is handled in TokenManager.
        ```
        """
    )

    guard case let .final(text)? = parsed else {
        Issue.record("Expected final answer")
        return
    }

    #expect(text == "Auth refresh is handled in TokenManager.")
}

@Test
func agentToolServiceRejectsUnsafeShellCommand() throws {
    let service = AgentToolService()
    let result = try service.execute(
        call: AgentToolCall(name: "shell", input: "swift test && rm -rf ."),
        workspaceRootURL: FileManager.default.temporaryDirectory,
        runID: nil
    )

    #expect(result.isError)
    #expect(result.output.contains("Rejected unsafe shell command"))
}

@Test
func agentToolServiceWritesAndEditsFilesInsideWorkspace() throws {
    let workspace = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let service = AgentToolService()

    let writeResult = try service.execute(
        call: AgentToolCall(
            name: "write_file",
            input: """
            path: Sources/App/Feature.swift
            content:
            struct Feature {
                let enabled = true
            }
            """
        ),
        workspaceRootURL: workspace,
        runID: nil
    )

    #expect(writeResult.isError == false)
    #expect(writeResult.output.contains("created: Sources/App/Feature.swift"))

    let editResult = try service.execute(
        call: AgentToolCall(
            name: "edit_file",
            input: """
            path: Sources/App/Feature.swift
            start: 2
            end: 2
            content:
                let enabled = false
            """
        ),
        workspaceRootURL: workspace,
        runID: nil
    )

    #expect(editResult.isError == false)
    let fileText = try String(
        contentsOf: workspace.appendingPathComponent("Sources/App/Feature.swift"),
        encoding: .utf8
    )
    #expect(fileText.contains("let enabled = false"))
}

@Test
func agentToolServiceRejectsPathsOutsideWorkspace() throws {
    let workspace = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let service = AgentToolService()

    let result = try service.execute(
        call: AgentToolCall(
            name: "write_file",
            input: """
            path: ../escape.swift
            content:
            print("bad")
            """
        ),
        workspaceRootURL: workspace,
        runID: nil
    )

    #expect(result.isError)
    #expect(result.output.contains("Path escapes workspace root"))
}

@Test
func agentLoopServiceExecutesToolAndReturnsFinalAnswer() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let root = PersistenceRoot(rootURL: directory.appendingPathComponent(".esh", isDirectory: true))
    let sources = directory.appendingPathComponent("Sources/Auth", isDirectory: true)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try """
    struct TokenManager {
        func refreshIfNeeded() {}
    }
    """.write(to: sources.appendingPathComponent("TokenManager.swift"), atomically: true, encoding: .utf8)

    let index = try ContextIndexer().buildIndex(workspaceRootURL: directory)
    let locator = WorkspaceContextLocator(root: root)
    let contextStore = ContextStore(locator: locator)
    try contextStore.save(index: index, workspaceRootURL: directory)

    let runtime = FakeAgentRuntime(replies: [
        """
        ```tool
        name: context_query
        input:
        refresh token auth
        ```
        """,
        """
        ```final
        Refresh logic is most likely in Sources/Auth/TokenManager.swift.
        ```
        """
    ])

    let packageStore = FileContextPackageStore(root: root)
    let result = try await AgentLoopService(
        toolService: AgentToolService(
            contextStore: contextStore,
            runStateStore: RunStateStore(root: root)
        ),
        contextStore: contextStore,
        packageService: ContextPackageService(store: packageStore)
    ).run(
        task: "Where is refresh auth handled?",
        session: ChatSession(name: "agent-test", modelID: "fake-model", backend: .mlx, cacheMode: .automatic, intent: .agentRun),
        runtime: runtime,
        workspaceRootURL: directory,
        maxSteps: 4
    )

    #expect(result.steps.count == 2)
    #expect(result.steps.first?.toolCall?.name == "context_query")
    #expect(result.steps.first?.toolResult?.output.contains("TokenManager.swift") == true)
    #expect(result.finalResponse.contains("TokenManager.swift"))
}

@Test
func agentLoopServiceCanWriteFileAndFinish() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let root = PersistenceRoot(rootURL: directory.appendingPathComponent(".esh", isDirectory: true))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let runtime = FakeAgentRuntime(replies: [
        """
        ```tool
        name: write_file
        input:
        path: Notes/todo.md
        content:
        # TODO
        - verify agent edits
        ```
        """,
        """
        ```final
        I created Notes/todo.md with the requested checklist.
        ```
        """
    ])

    let result = try await AgentLoopService(
        toolService: AgentToolService(runStateStore: RunStateStore(root: root))
    ).run(
        task: "Create a small TODO note",
        session: ChatSession(name: "agent-write-test", modelID: "fake-model", backend: .mlx, cacheMode: .automatic, intent: .agentRun),
        runtime: runtime,
        workspaceRootURL: directory,
        maxSteps: 4
    )

    let fileURL = directory.appendingPathComponent("Notes/todo.md")
    let fileText = try String(contentsOf: fileURL, encoding: .utf8)
    #expect(result.steps.first?.toolCall?.name == "write_file")
    #expect(fileText.contains("verify agent edits"))
    #expect(result.finalResponse.contains("Notes/todo.md"))
}

private final class FakeAgentRuntime: @unchecked Sendable, BackendRuntime {
    let backend: BackendKind = .mlx
    let modelID: String = "fake-model"

    private let lock = NSLock()
    private var replies: [String]

    init(replies: [String]) {
        self.replies = replies
    }

    var metrics: Metrics {
        get async { Metrics() }
    }

    func prepare(session: ChatSession) async throws {}

    func generate(
        session: ChatSession,
        config: GenerationConfig
    ) -> AsyncThrowingStream<String, Error> {
        let reply: String
        lock.lock()
        if replies.isEmpty {
            reply = "```final\nNo more replies.\n```"
        } else {
            reply = replies.removeFirst()
        }
        lock.unlock()

        return AsyncThrowingStream { continuation in
            continuation.yield(reply)
            continuation.finish()
        }
    }

    func exportRuntimeCache() async throws -> CacheSnapshot {
        CacheSnapshot(format: "fake", tensors: [])
    }

    func importRuntimeCache(_ snapshot: CacheSnapshot) async throws {}

    func validateCacheCompatibility(_ manifest: CacheManifest) async throws {}

    func unload() async {}
}
