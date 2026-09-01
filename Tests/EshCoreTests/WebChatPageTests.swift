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

    @Test
    func picker2UsesOneConsistentRowPatternNoRadios() {
        let html = WebChatPage.html(toolVersion: nil)
        // The picker is a single row family (rounded highlight + right-aligned check), built by pickRow().
        #expect(html.contains("function pickRow("))
        #expect(html.contains(".pickrow"))
        // Optimize-for is rendered through the same pickRow pattern, not a radio control.
        #expect(html.contains("pickRow(o,o===S.optimize,'pickOptimize'"))
        // The picker sections match the approved layout order.
        #expect(html.contains("Installed"))
        #expect(html.contains("Built into this Mac"))
        #expect(html.contains("Manage models"))
    }

    @Test
    func modelAndEffortControlsLiveInTheComposer() {
        let html = WebChatPage.html(toolVersion: nil)
        // The model picker and effort control are chips in the composer (progressive disclosure at the
        // point of use), not in the top-right header.
        #expect(html.contains("class=\"cchip\" data-act=\"togglePicker\""))
        #expect(html.contains("data-act=\"toggleEffort\""))
        #expect(html.contains("function effortWord("))
        #expect(html.contains("function renderEffort("))
        // Effort is the reasoning control surfaced here: Off disables reasoning; Low/Medium/High reason.
        #expect(html.contains("pickEffort"))
        #expect(html.contains("Faster"))
        #expect(html.contains("Smarter"))
        // The header no longer carries a model button.
        #expect(html.contains("class=\"modelbtn\"") == false)
        // The composer is a column so the input fills the row and the chips sit flush-right.
        #expect(html.contains("flex-direction:column"))
        // Chips toggle closed on re-click, and any open popover closes on an outside click.
        #expect(html.contains("const was=S.pickerOpen; closeAll(); S.pickerOpen=!was"))
        #expect(html.contains("!e.target.closest('.pop')"))
        // The effort slider is draggable, not click-only.
        #expect(html.contains("function wireEffortSlider("))
        #expect(html.contains("setPointerCapture"))
        #expect(html.contains("onpointermove"))
    }

    @Test
    func contextualStatusLineSurfacesTheMomentAndOpensEngine() {
        let html = WebChatPage.html(toolVersion: nil)
        #expect(html.contains("function statusInfo("))
        // Real signals only: external-storage disconnect, generating, warm, ready.
        #expect(html.contains("External storage disconnected"))
        #expect(html.contains("· generating"))
        #expect(html.contains(" warm"))
        #expect(html.contains("Local · Private · Ready"))
        // Still opens the same Engine menu.
        #expect(html.contains("data-act=\"toggleEngine\""))
    }

    @Test
    func voiceIsAFullConversationalLoop() {
        let html = WebChatPage.html(toolVersion: nil)
        // Listening → Thinking → Speaking states with orb/dots/waveform.
        #expect(html.contains(".vpulse"))
        #expect(html.contains(".vdots"))
        #expect(html.contains(".vwave"))
        // Two round 44px controls (keyboard = back to text, dark X = end) and the transcript footer.
        #expect(html.contains("ICON.keyboard"))
        #expect(html.contains("Everything is transcribed into the chat"))
        // Every finished exchange is committed with a voice footer.
        #expect(html.contains("'voice · '"))
        // The loop is real: mic → STT → LLM → TTS.
        #expect(html.contains("getUserMedia"))
        #expect(html.contains("MediaRecorder"))
        // Hands-free: silence detection auto-advances listening without a tap.
        #expect(html.contains("function startVAD("))
        #expect(html.contains("AudioContext"))
        #expect(html.contains("getByteTimeDomainData"))
        #expect(html.contains("Just pause when you"))
    }

    @Test
    func composerKeepsFocusAfterSending() {
        let html = WebChatPage.html(toolVersion: nil)
        // After a send completes, focus returns to the input (focusInput re-armed), and the trailing
        // throttle render is cancelled so it can't rebuild the composer and steal focus.
        #expect(html.contains("S.focusInput=true; saveChats(); render();"))
        #expect(html.contains("clearTimeout(_rt)"))
    }

    @Test
    func settingsHasEveryPane() {
        let html = WebChatPage.html(toolVersion: nil)
        for pane in ["General", "Intelligence", "Models", "Voice", "Performance", "Storage", "Privacy", "Advanced"] {
            #expect(html.contains(pane))
        }
        // General + Intelligence controls that actually change client behavior.
        #expect(html.contains("Send with Enter"))
        #expect(html.contains("Save conversation history"))
        #expect(html.contains("Auto routing"))
        #expect(html.contains("System instructions"))
    }
}
