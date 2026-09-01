import Foundation
import Testing
@testable import EshCore

@Suite
struct WebChatPageTests {
    @Test
    func pageIsSelfContainedAndUsesCanonicalAPIs() {
        let html = WebChatPage.html(toolVersion: "9.9.9")
        // Self-contained: no external asset hosts.
        #expect(html.contains("src=\"http") == false)
        #expect(html.contains("cdn.") == false)
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

    @Test
    func pageOffersChatGPTLikeFeatures() {
        let html = WebChatPage.html(toolVersion: nil)
        // Multi-conversation history + new chat.
        #expect(html.contains("New chat"))
        #expect(html.contains("localStorage"))
        // Settings the CLI also exposes.
        #expect(html.contains("System prompt"))
        #expect(html.contains("Temperature"))
        #expect(html.contains("Max tokens"))
        #expect(html.contains("Reasoning"))
        #expect(html.contains("compression") || html.contains("cache_mode"))
        // Collapsible reasoning display.
        #expect(html.contains("</think>"))
        #expect(html.contains("details"))
        // Speech: text-to-speech playback + speech-to-text upload.
        #expect(html.contains("/v1/audio/speech"))
        #expect(html.contains("/v1/audio/transcriptions"))
        // Multimodal rendering + attachments.
        #expect(html.contains("<audio") || html.contains("audio"))
        #expect(html.contains("type=\"file\""))
    }

    @Test
    func versionlessPageStampsEmptyVersion() {
        let html = WebChatPage.html(toolVersion: nil)
        #expect(html.contains("__VERSION__") == false)
    }
}
