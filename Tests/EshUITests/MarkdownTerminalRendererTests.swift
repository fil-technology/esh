import Testing
@testable import esh

@Suite
struct MarkdownTerminalRendererTests {
    @Test
    func rendersHeadingsListsAndInlineCode() {
        let lines = MarkdownTerminalRenderer.render(
            """
            ## Overview
            - Use `esh chat`
            1. Install model
            """,
            width: 60
        )

        #expect(lines.contains { TerminalUIStyle.stripANSI(from: $0.text) == "Overview" })
        #expect(lines.contains { TerminalUIStyle.stripANSI(from: $0.text) == "• Use `esh chat`" })
        #expect(lines.contains { TerminalUIStyle.stripANSI(from: $0.text) == "1. Install model" })
    }

    @Test
    func rendersQuotesLinksAndCodeBlocks() {
        let lines = MarkdownTerminalRenderer.render(
            """
            > Read [docs](https://example.com)

            ```swift
            let x = 1
            ```
            """,
            width: 60
        )

        #expect(lines.contains { TerminalUIStyle.stripANSI(from: $0.text) == "▌ Read docs <https://example.com>" })
        #expect(lines.contains { TerminalUIStyle.stripANSI(from: $0.text) == "code swift" })
        #expect(lines.contains { TerminalUIStyle.stripANSI(from: $0.text).contains("let x = 1") })
    }

    @Test
    func syntaxHighlightsSwiftCodeBlocks() {
        let lines = MarkdownTerminalRenderer.render(
            """
            ```swift
            // comment
            let age = 25
            print("hi")
            ```
            """,
            width: 60
        )

        let commentLine = lines.first { TerminalUIStyle.stripANSI(from: $0.text).contains("// comment") }
        let keywordLine = lines.first { TerminalUIStyle.stripANSI(from: $0.text).contains("let age = 25") }
        let stringLine = lines.first { TerminalUIStyle.stripANSI(from: $0.text).contains("print(\"hi\")") }

        #expect(commentLine != nil)
        #expect(keywordLine != nil)
        #expect(stringLine != nil)
        #expect(commentLine?.text != TerminalUIStyle.stripANSI(from: commentLine?.text ?? ""))
        #expect(keywordLine?.text != TerminalUIStyle.stripANSI(from: keywordLine?.text ?? ""))
        #expect(stringLine?.text != TerminalUIStyle.stripANSI(from: stringLine?.text ?? ""))
    }
}
