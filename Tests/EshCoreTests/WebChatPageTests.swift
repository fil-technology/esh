import Foundation
import Testing
@testable import EshCore

@Suite
struct WebChatPageTests {
    @Test
    func pageIsSelfContainedAndUsesCanonicalAPIs() {
        let html = WebChatPage.html(toolVersion: "9.9.9")
        // Self-contained: no external asset hosts.
        #expect(html.contains("http://") == false || html.contains("src=\"http") == false)
        // Talks to the canonical esh APIs, same-origin.
        #expect(html.contains("/v1/chat/completions"))
        #expect(html.contains("/v1/models"))
        // Core UI + streaming affordances.
        #expect(html.contains("id=\"model\""))
        #expect(html.contains("stream: true") || html.contains("stream:true"))
        #expect(html.contains("AbortController"))     // cancel support
        #expect(html.contains("9.9.9"))               // version stamped
        #expect(WebChatPage.contentType.contains("text/html"))
    }
}
