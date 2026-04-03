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
}
