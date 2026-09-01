import Foundation
import Testing
@testable import EshCore

@Suite
struct WebChatPageTests {
    @Test
    func pageIsSelfContainedThinClientOverCanonicalAPIs() {
        let html = WebChatPage.html(toolVersion: "9.9.9")
        // Self-contained (Google Fonts is the one allowed external, matching the design system).
        #expect(html.contains("src=\"http") == false)
        #expect(html.contains("cdn.") == false)
        // Thin client over the canonical endpoints — no runtime/policy logic invented in JS.
        #expect(html.contains("/v1/chat/completions"))
        #expect(html.contains("/v1/models"))
        #expect(html.contains("/v1/engine"))      // engine inspector + status
        #expect(html.contains("/v1/schedule"))    // Auto + "Why this model?"
        #expect(html.contains("/v1/catalog"))     // model browser + fit
        #expect(html.contains("/v1/config"))      // settings
        #expect(WebChatPage.contentType.contains("text/html"))
    }

    @Test
    func usesTheApprovedVisualLanguage() {
        let html = WebChatPage.html(toolVersion: nil)
        // Warm paper + graphite ink, amber only for warnings; IBM Plex Mono for technical data.
        #expect(html.contains("#fbfaf8"))          // paper
        #expect(html.contains("#201e1b"))          // ink
        #expect(html.contains("IBM Plex Mono"))
        // Inline SVG icons, not emoji glyphs, for chrome.
        #expect(html.contains("<svg"))
    }

    @Test
    func hasTheProgressiveDisclosureSurfaces() {
        let html = WebChatPage.html(toolVersion: nil)
        // Default simple surface.
        #expect(html.contains("What can I help with?"))
        #expect(html.contains("New chat"))
        #expect(html.contains("Ask anything"))
        // Auto/model, engine, execution, models, settings, voice.
        #expect(html.contains("Auto"))
        #expect(html.contains("Optimize for") || html.contains("OPTIMIZE"))
        #expect(html.contains("Why this model?"))
        #expect(html.contains("Browse models"))
        #expect(html.contains("Execution"))
        #expect(html.contains("Engine"))
        #expect(html.contains("Privacy"))
        // Streaming + reasoning + speech behaviors preserved.
        #expect(html.contains("</think>"))
        #expect(html.contains("/v1/audio/speech"))
        #expect(html.contains("/v1/audio/transcriptions"))
        #expect(html.contains("localStorage"))    // history + presentation prefs are browser-local
    }
}
