import Foundation
import Testing
import EshCore
@testable import EshRuntime

// §5 tests: reasoning separation (streaming + one-shot), structured-output resolution, and honest tool
// acceptance — plus unit tests for the streaming reasoning splitter (including tags split across chunks).

private struct ChunkRuntime: BackendRuntime, @unchecked Sendable {
    let backend: BackendKind
    let modelID: String
    let chunks: [String]
    var metrics: Metrics { get async { Metrics(finishReason: "stop") } }
    func prepare(session: ChatSession) async throws {}
    func generate(session: ChatSession, config: GenerationConfig) -> AsyncThrowingStream<String, Error> {
        let chunks = self.chunks
        return AsyncThrowingStream { c in for ch in chunks { c.yield(ch) }; c.finish() }
    }
    func exportRuntimeCache() async throws -> CacheSnapshot { throw StoreError.invalidManifest("m") }
    func importRuntimeCache(_ snapshot: CacheSnapshot) async throws { throw StoreError.invalidManifest("m") }
    func validateCacheCompatibility(_ manifest: CacheManifest) async throws { throw CompatibilityIssue(reason: "m") }
    func unload() async {}
}

private struct ChunkBackend: InferenceBackend, @unchecked Sendable {
    let kind: BackendKind
    let runtimeVersion = "mock"
    let chunks: [String]
    func capabilityReport(for install: ModelInstall) -> BackendCapabilityReport {
        BackendCapabilityReport(backend: kind, runtimeVersion: runtimeVersion, ready: true, supportedFeatures: [.directInference])
    }
    func loadRuntime(for install: ModelInstall) async throws -> BackendRuntime {
        ChunkRuntime(backend: kind, modelID: install.id, chunks: chunks)
    }
    func makeCompatibilityChecker(for install: ModelInstall) -> CompatibilityChecking { ChunkChecker() }
}
private struct ChunkChecker: CompatibilityChecking { func validate(manifest: CacheManifest) throws {} }

private func runtime(_ chunks: [String]) -> EshRuntime {
    EshRuntime(registry: InferenceBackendRegistry(backends: [.apple: ChunkBackend(kind: .apple, chunks: chunks)]))
}

@Suite struct TextEventsTests {

    // MARK: Splitter unit tests

    @Test func splitterSeparatesReasoningFromAnswer() {
        var s = ReasoningStreamSplitter()
        var visible = "", reasoning = ""
        // tags deliberately split across chunk boundaries
        for chunk in ["<thi", "nk>rea", "soning</thi", "nk>ans", "wer"] {
            let (v, r) = s.ingest(chunk, final: false); visible += v; reasoning += r
        }
        let (v, r) = s.ingest("", final: true); visible += v; reasoning += r
        #expect(reasoning == "reasoning")
        #expect(visible == "answer")
    }

    @Test func splitterPassesThroughPlainText() {
        var s = ReasoningStreamSplitter()
        var visible = ""
        for chunk in ["hello ", "world"] { visible += s.ingest(chunk, final: false).visible }
        visible += s.ingest("", final: true).visible
        #expect(visible == "hello world")
    }

    @Test func generateHandlesImplicitOpenReasoning() async throws {
        // DeepSeek-style implicit open (no leading <think>, only a trailing </think>). Live streaming can't
        // split this, but the authoritative final result (one-shot generate / completed) does.
        let rt = runtime(["thinking here", "</think>", "the answer"])
        var cfg = GenerationConfig(); cfg.enableThinking = true
        let r = try await rt.generate(EshGenerationRequest(prompt: "x", config: cfg))
        #expect(r.reasoning == "thinking here")
        #expect(r.text == "the answer")
    }

    // MARK: End-to-end reasoning

    @Test func streamEmitsReasoningThenTokens() async throws {
        let rt = runtime(["<think>", "why 4", "</think>", "4"])
        var reasoning = "", visible = ""
        var result: EshGenerationResult?
        var cfg = GenerationConfig(); cfg.enableThinking = true
        for try await ev in rt.stream(EshGenerationRequest(prompt: "2+2?", config: cfg)) {
            switch ev {
            case .reasoningDelta(let r): reasoning += r
            case .token(let t): visible += t
            case .completed(let r): result = r
            case .toolCall: break
            }
        }
        #expect(reasoning == "why 4")
        #expect(visible == "4")
        #expect(result?.text == "4")
        #expect(result?.reasoning == "why 4")
    }

    @Test func generateSeparatesReasoning() async throws {
        let rt = runtime(["<think>step</think>", "final"])
        var cfg = GenerationConfig(); cfg.enableThinking = true
        let result = try await rt.generate(EshGenerationRequest(prompt: "x", config: cfg))
        #expect(result.text == "final")
        #expect(result.reasoning == "step")
    }

    @Test func plainStreamUnchangedWhenThinkingOff() async throws {
        let rt = runtime(["a", "b", "c"])
        var tokens: [String] = []
        for try await ev in rt.stream(EshGenerationRequest(prompt: "x")) {
            if case .token(let t) = ev { tokens.append(t) }
        }
        #expect(tokens == ["a", "b", "c"])   // no splitting when thinking is off — identical to pre-§5
    }

    // MARK: Structured output + tools resolution (honest)

    @Test func structuredOutputSurfacesResolution() async throws {
        let rt = runtime(["{}"])
        let req = EshGenerationRequest(prompt: "give json",
                                       responseFormat: EshResponseFormat(kind: .json))
        let result = try await rt.generate(req)
        #expect(result.capabilityResolution != nil)   // resolver ran and recorded how json was handled
    }

    @Test func toolsAreAcceptedAndHonestlyReportedRejected() async throws {
        let rt = runtime(["ok"])
        let req = EshGenerationRequest(prompt: "use a tool",
                                       tools: [EshToolDefinition(name: "get_time")])
        let result = try await rt.generate(req)
        // Native local tool-calling is not available — the resolution must say so honestly, and no
        // .toolCall is fabricated.
        #expect(result.capabilityResolution?.first(named: "tools")?.resolution == .rejected)
    }
}
