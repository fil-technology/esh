import Foundation
import Testing
@testable import EshCore

@Suite
struct StreamingChatTests {
    @Test
    func streamProviderEmitsIncrementalDeltasThenDone() async {
        // A service whose streaming closure yields two tokens.
        let service = OpenAICompatibleService(
            infer: { _ in throw OpenAICompatibleError.unsupported("buffered path not used") },
            stream: { _ in
                AsyncThrowingStream { c in c.yield("Hello"); c.yield(" world"); c.finish() }
            },
            installedModels: { [] }
        )
        let req = OpenAIChatCompletionsRequest(
            model: "m", messages: [.init(role: "user", content: .text("hi"))], stream: true)
        let provider = service.chatCompletionsStreamProvider(req)
        #expect(provider != nil)

        // Collect the SSE bytes the provider writes.
        final class Sink: @unchecked Sendable { var data = Data(); let lock = NSLock()
            func add(_ d: Data) { lock.lock(); data.append(d); lock.unlock() } }
        let sink = Sink()
        await provider?({ chunk in sink.add(chunk) })
        let text = String(decoding: sink.data, as: UTF8.self)

        #expect(text.contains("Hello"))
        #expect(text.contains(" world"))
        #expect(text.contains("\"role\":\"assistant\""))    // initial role delta
        #expect(text.contains("\"finish_reason\":\"stop\"") || text.contains("\"finishReason\":\"stop\""))
        #expect(text.contains("[DONE]"))
    }

    @Test
    func noStreamClosureMeansNoProvider() {
        let service = OpenAICompatibleService(
            infer: { _ in throw OpenAICompatibleError.unsupported("x") },
            installedModels: { [] })
        let req = OpenAIChatCompletionsRequest(model: "m", messages: [.init(role: "user", content: .text("hi"))], stream: true)
        #expect(service.chatCompletionsStreamProvider(req) == nil)   // falls back to buffered
    }
}
