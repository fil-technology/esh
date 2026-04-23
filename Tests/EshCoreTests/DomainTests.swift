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
