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

@Test
func promptCacheKeyStabilizesEquivalentSessionsAndIncludesModelAndTools() {
    let normalizer = PromptSessionNormalizer()
    let left = ChatSession(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        name: "demo",
        messages: [
            Message(role: .system, text: "  system line  \r\n"),
            Message(role: .user, text: "  hello\t")
        ]
    )
    let right = ChatSession(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        name: "renamed",
        messages: [
            Message(role: .system, text: "system line"),
            Message(role: .user, text: "hello")
        ]
    )

    let leftKey = normalizer.promptCacheKey(
        for: left,
        backend: .mlx,
        modelID: "qwen",
        tokenizerID: "tok",
        runtimeVersion: "mlx-test",
        toolSignature: "tools:none"
    )
    let rightKey = normalizer.promptCacheKey(
        for: right,
        backend: .mlx,
        modelID: "qwen",
        tokenizerID: "tok",
        runtimeVersion: "mlx-test",
        toolSignature: "tools:none"
    )
    let differentToolsKey = normalizer.promptCacheKey(
        for: right,
        backend: .mlx,
        modelID: "qwen",
        tokenizerID: "tok",
        runtimeVersion: "mlx-test",
        toolSignature: "tools:read_file@v1"
    )

    #expect(leftKey == rightKey)
    #expect(leftKey.hash != differentToolsKey.hash)
    #expect(leftKey.normalizedMessageCount == 2)
    #expect(leftKey.backend == .mlx)
    #expect(leftKey.modelID == "qwen")
}
