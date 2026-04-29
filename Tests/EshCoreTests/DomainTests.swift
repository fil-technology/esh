import Foundation
import Testing
@testable import EshCore

@Test
func sessionRoundTripBasics() throws {
    let session = ChatSession(name: "default", messages: [
        Message(role: .user, text: "Hello")
    ])

    let data = try JSONCoding.encoder.encode(session)
    let decoded = try JSONCoding.decoder.decode(ChatSession.self, from: data)

    #expect(decoded.name == "default")
    #expect(decoded.messages.count == 1)
}

@Test
func sessionRoundTripPreservesIntentAndCacheMode() throws {
    let session = ChatSession(
        name: "code-session",
        cacheMode: .automatic,
        intent: .code,
        messages: [Message(role: .user, text: "Write a parser.")]
    )

    let data = try JSONCoding.encoder.encode(session)
    let decoded = try JSONCoding.decoder.decode(ChatSession.self, from: data)

    #expect(decoded.cacheMode == .automatic)
    #expect(decoded.intent == .code)
}

@Test
func generationConfigDecodesDefaultsAndSamplingOptions() throws {
    let config = try JSONCoding.decoder.decode(
        GenerationConfig.self,
        from: Data(
            """
            {
              "max_tokens": 128,
              "temperature": 0.2,
              "top_p": 0.9,
              "top_k": 40,
              "min_p": 0.05,
              "repetition_penalty": 1.1,
              "seed": 42
            }
            """.utf8
        )
    )

    #expect(config.maxTokens == 128)
    #expect(config.temperature == 0.2)
    #expect(config.topP == 0.9)
    #expect(config.topK == 40)
    #expect(config.minP == 0.05)
    #expect(config.repetitionPenalty == 1.1)
    #expect(config.seed == 42)

    let defaults = try JSONCoding.decoder.decode(GenerationConfig.self, from: Data("{}".utf8))
    #expect(defaults.maxTokens == 512)
    #expect(defaults.temperature == 0.7)
}
