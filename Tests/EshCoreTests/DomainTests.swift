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
