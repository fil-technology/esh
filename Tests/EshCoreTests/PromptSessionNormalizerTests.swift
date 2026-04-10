import Foundation
import Testing
@testable import EshCore

@Test
func promptNormalizerStabilizesEquivalentWhitespace() {
    let normalizer = PromptSessionNormalizer()
    let left = ChatSession(
        name: "demo",
        messages: [
            Message(role: .system, text: "  system line  \r\n\r\n"),
            Message(role: .user, text: "\r\nprint('hi')   \r\n")
        ]
    )
    let right = ChatSession(
        name: "demo",
        messages: [
            Message(role: .system, text: "system line"),
            Message(role: .user, text: "print('hi')")
        ]
    )

    let normalizedLeft = normalizer.normalized(session: left)
    let normalizedRight = normalizer.normalized(session: right)

    #expect(normalizedLeft.messages.map(\.text) == normalizedRight.messages.map(\.text))
}

@Test
func promptNormalizerDropsEmptyMessages() {
    let normalizer = PromptSessionNormalizer()
    let session = ChatSession(
        name: "demo",
        messages: [
            Message(role: .system, text: "   \r\n  "),
            Message(role: .user, text: "hello")
        ]
    )

    let normalized = normalizer.normalized(session: session)

    #expect(normalized.messages.count == 1)
    #expect(normalized.messages.first?.text == "hello")
}
