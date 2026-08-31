import Foundation
import Testing
@testable import EshCore

@Suite
struct StreamEventTests {

    @Test
    func textStreamAdaptsToDeltasThenDone() async throws {
        let runtime = ChunkRuntime(chunks: ["Hel", "lo", " world"])
        var events: [EshStreamEvent] = []
        for try await event in ChatService().streamEvents(runtime: runtime, session: Self.session()) {
            events.append(event)
        }
        #expect(events == [
            .textDelta("Hel"),
            .textDelta("lo"),
            .textDelta(" world"),
            .done(finishReason: "stop")
        ])
        #expect(events.collectedText() == "Hello world")
        #expect(events.last?.isTerminal == true)
    }

    @Test
    func emptyChunksAreNotEmittedAsDeltas() async throws {
        let runtime = ChunkRuntime(chunks: ["", "a", ""])
        var events: [EshStreamEvent] = []
        for try await event in ChatService().streamEvents(runtime: runtime, session: Self.session()) {
            events.append(event)
        }
        #expect(events == [.textDelta("a"), .done(finishReason: "stop")])
    }

    @Test
    func runtimeErrorBecomesTerminalFailedEvent() async throws {
        let runtime = ChunkRuntime(chunks: ["partial"], throwAfter: true)
        var events: [EshStreamEvent] = []
        for try await event in ChatService().streamEvents(runtime: runtime, session: Self.session()) {
            events.append(event)
        }
        #expect(events.first == .textDelta("partial"))
        guard case .failed = events.last else {
            Issue.record("expected a terminal .failed event, got \(String(describing: events.last))")
            return
        }
    }

    private static func session() -> ChatSession {
        ChatSession(
            name: "s",
            modelID: "m",
            messages: [Message(role: .user, text: "hi")]
        )
    }
}

/// A runtime that yields fixed chunks, optionally throwing after them.
private final class ChunkRuntime: BackendRuntime, @unchecked Sendable {
    let backend: BackendKind = .mlx
    let modelID: String = "chunk"
    var metrics: Metrics = .init()
    private let chunks: [String]
    private let throwAfter: Bool

    init(chunks: [String], throwAfter: Bool = false) {
        self.chunks = chunks
        self.throwAfter = throwAfter
    }

    func prepare(session: ChatSession) async throws {}

    func generate(session: ChatSession, config: GenerationConfig) -> AsyncThrowingStream<String, Error> {
        let chunks = self.chunks
        let throwAfter = self.throwAfter
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            if throwAfter {
                continuation.finish(throwing: StoreError.invalidManifest("boom"))
            } else {
                continuation.finish()
            }
        }
    }

    func exportRuntimeCache() async throws -> CacheSnapshot { CacheSnapshot(format: "mlx", tensors: []) }
    func importRuntimeCache(_ snapshot: CacheSnapshot) async throws {}
    func validateCacheCompatibility(_ manifest: CacheManifest) async throws {}
    func unload() async {}
}
