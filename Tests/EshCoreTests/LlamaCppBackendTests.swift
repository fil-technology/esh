import Foundation
import Testing
@testable import EshCore

@Suite
struct LlamaCppBackendTests {
    // Regression guard for the GGUF runaway-generation blocker: esh used to hand-build a
    // "User:/Assistant:" plaintext transcript, which is NOT the model's chat format — so the model
    // never emitted its native end-of-turn token and ran away into a hallucinated transcript. The
    // request must instead be an OpenAI `messages` array so llama-server applies the model's own chat
    // template (`--jinja`) and stops at the native assistant-turn end.

    private func session(_ messages: [(Message.Role, String)]) -> ChatSession {
        ChatSession(name: "t", messages: messages.map { Message(role: $0.0, text: $0.1) })
    }

    private func decoded(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    @Test
    func requestUsesAChatMessagesArrayNotAHandBuiltTranscript() throws {
        let s = session([(.system, "You are helpful."), (.user, "hi"), (.assistant, "hello"), (.user, "what is Taiwan?")])
        let body = try LlamaServerRuntime.requestBody(session: s, config: GenerationConfig(maxTokens: 64, temperature: 0.5))
        let obj = decoded(body)
        let messages = obj["messages"] as? [[String: String]]
        #expect(messages != nil)
        #expect(messages?.count == 4)
        #expect(messages?.first?["role"] == "system")
        #expect(messages?.last?["role"] == "user")
        #expect(messages?.last?["content"] == "what is Taiwan?")
        // No hand-built role transcript, and streaming is on.
        #expect(obj["prompt"] == nil)
        #expect(obj["stream"] as? Bool == true)
        // Sampling passes through.
        #expect(obj["max_tokens"] as? Int == 64)
        #expect((obj["temperature"] as? Double) == 0.5)
    }

    @Test
    func constrainedDecodingPrefersJSONSchemaOverGrammar() throws {
        let s = session([(.user, "give me json")])
        let jsonBody = decoded(try LlamaServerRuntime.requestBody(
            session: s, config: GenerationConfig(jsonSchema: #"{"type":"object"}"#)))
        let rf = jsonBody["response_format"] as? [String: Any]
        #expect(rf?["type"] as? String == "json_schema")
        #expect(jsonBody["grammar"] == nil)

        let grammarBody = decoded(try LlamaServerRuntime.requestBody(
            session: s, config: GenerationConfig(grammar: "root ::= \"yes\" | \"no\"")))
        #expect(grammarBody["grammar"] as? String == "root ::= \"yes\" | \"no\"")
        #expect(grammarBody["response_format"] == nil)

        // JSON schema wins when both are present.
        let bothBody = decoded(try LlamaServerRuntime.requestBody(
            session: s, config: GenerationConfig(jsonSchema: #"{"type":"object"}"#, grammar: "root ::= \"x\"")))
        #expect(bothBody["response_format"] != nil)
        #expect(bothBody["grammar"] == nil)
    }

    @Test
    func samplingAndCallerStopSequencesPassThrough() throws {
        let s = session([(.user, "count")])
        let body = decoded(try LlamaServerRuntime.requestBody(
            session: s,
            config: GenerationConfig(maxTokens: 16, temperature: 0.9, topP: 0.8, topK: 40,
                                     minP: 0.05, repetitionPenalty: 1.1, seed: 7, stop: ["<END>", "\n\n"])))
        #expect(body["top_p"] as? Double == 0.8)
        #expect(body["top_k"] as? Int == 40)
        #expect(body["min_p"] as? Double == 0.05)
        #expect(body["repeat_penalty"] as? Double == 1.1)
        #expect(body["seed"] as? Int == 7)
        #expect(body["stop"] as? [String] == ["<END>", "\n\n"])
    }

    @Test
    func runtimeNotFoundMessageMentionsTheServer() {
        #expect(LlamaCppBackend.runtimeNotFoundMessage.contains("llama-server"))
    }
}
