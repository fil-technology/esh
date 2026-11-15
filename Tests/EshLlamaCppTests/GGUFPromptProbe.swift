import Foundation
import Testing
import EshCore
import esh_llama
@testable import EshLlamaCpp

// Env-gated probe (issue #41): the embedded path's EXACT rendered prompt and prompt tokens for a conversation.
//   ESH_GGUF_PROBE_MODEL  path to a .gguf    ESH_GGUF_PROBE_OUT  JSON file to write
@Test func ggufEmbeddedPromptProbe() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let modelPath = env["ESH_GGUF_PROBE_MODEL"], let out = env["ESH_GGUF_PROBE_OUT"] else { return }
    let context = try await LlamaContext.make(modelPath: modelPath, config: .init(contextTokens: 2048))
    var params = llama_model_default_params()
    params.vocab_only = true
    let model = try #require(llama_model_load_from_file(modelPath, params))
    defer { llama_model_free(model) }
    let vocab = try #require(llama_model_get_vocab(model))
    func tokens(_ text: String) -> [Int32] {
        let utf8 = Array(text.utf8CString)
        var buf = [llama_token](repeating: 0, count: utf8.count + 16)
        let n = buf.withUnsafeMutableBufferPointer { tb in
            utf8.withUnsafeBufferPointer { llama_tokenize(vocab, $0.baseAddress, Int32(utf8.count - 1), tb.baseAddress, Int32(tb.count), true, true) }
        }
        return Array(buf.prefix(Int(max(0, n))))
    }
    let cases: [String: [Message]] = [
        "noSystem": [Message(role: .user, text: "In one sentence, what is a KV cache?")],
        "withSystem": [Message(role: .system, text: "You are terse."), Message(role: .user, text: "In one sentence, what is a KV cache?")],
        "multiTurn": [Message(role: .user, text: "Hi"), Message(role: .assistant, text: "Hello!"), Message(role: .user, text: "Bye")],
    ]
    var result: [String: Any] = [:]
    for (name, messages) in cases {
        let prompt = await context.formatPrompt(session: ChatSession(name: name, backend: .gguf, messages: messages))
        result[name] = ["prompt": prompt, "tokens": tokens(prompt)]
    }
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: out))
}
