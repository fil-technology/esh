import Foundation

public struct ChatService: Sendable {
    public init() {}

    public func streamReply(
        runtime: BackendRuntime,
        session: ChatSession,
        config: GenerationConfig = .init()
    ) -> AsyncThrowingStream<String, Error> {
        runtime.generate(session: session, config: config)
    }

    /// Adapt the runtime's raw text stream into the canonical `EshStreamEvent` envelope (M8). Emits
    /// `.textDelta` per non-empty chunk, then a terminal `.done` on success or `.failed` on error.
    /// Cancellation propagates as a thrown `CancellationError` (not a `.failed` event) so callers can
    /// distinguish an aborted stream from a runtime failure. Only genuinely observed events are
    /// emitted — reasoning/tool/usage events are added by richer producers, never invented here.
    public func streamEvents(
        runtime: BackendRuntime,
        session: ChatSession,
        config: GenerationConfig = .init(),
        finishReason: String = "stop"
    ) -> AsyncThrowingStream<EshStreamEvent, Error> {
        let textStream = runtime.generate(session: session, config: config)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in textStream {
                        if chunk.isEmpty == false {
                            continuation.yield(.textDelta(chunk))
                        }
                    }
                    continuation.yield(.done(finishReason: finishReason))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.yield(.failed(message: error.localizedDescription))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
