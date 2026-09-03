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
        // Picking a model/effort or closing a popover returns focus to the input.
        #expect(html.contains("S.focusInput=true; if(v==='Auto')refreshSchedule()"))
        #expect(html.contains("if(!S.effortOpen)S.focusInput=true"))
    }

    @Test
    func attachmentsRenderInTheBubbleAndReachTheModel() {
        let html = WebChatPage.html(toolVersion: nil)
        // Document/text attachments render as a pill in the sent bubble (not only image/audio).
        #expect(html.contains(".attpill"))
        #expect(html.contains("class=\"attwrap\""))
        // Their text is decoded and appended to the outgoing model message.
        #expect(html.contains("function attText("))
        #expect(html.contains("[Attached file: "))
    }

    @Test
    func voiceSpeakingUpdatesInPlaceWithoutFlicker() {
        let html = WebChatPage.html(toolVersion: nil)
        // The spoken answer updates a single node (#vanswer) rather than re-rendering the whole app.
        #expect(html.contains("id=\"vanswer\""))
        #expect(html.contains("getElementById('vanswer')"))
    }

    @Test
    func voiceSettingsAreRealDropdownsFromTheAudioCatalog() {
        let html = WebChatPage.html(toolVersion: nil)
        // Voice model / speaker / language / STT are functional dropdowns fed by the real audio catalog.
        #expect(html.contains("function renderVoicePane("))
        #expect(html.contains("function vdropRow("))
        #expect(html.contains("/v1/audio/models"))
        #expect(html.contains("pickTtsModel"))
        #expect(html.contains("pickTtsVoice"))
        #expect(html.contains("pickSttModel"))
        // The chosen TTS model/voice/language are sent with each speech request.
        #expect(html.contains("body.voice=S.prefs.ttsVoice"))
        // Honesty: the UI must NOT hardcode a fabricated speech-model list — names come from the API.
        #expect(html.contains("Kokoro") == false)
        #expect(html.contains("Ember") == false)
        #expect(html.contains("Whisper Large") == false)
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
    func voiceLoopStreamsAndSpeaksPerSentenceForFastFirstAudio() {
        let html = WebChatPage.html(toolVersion: nil)
        // The voice turn streams the reply and synthesizes/plays it sentence-by-sentence.
        #expect(html.contains("function speakBlob("))
        #expect(html.contains("blobP:speakBlob(chunk)"))
        // The voice inference is streamed (not a single blocking completion).
        #expect(html.contains("stream:true,max_tokens:512"))
    }

    @Test
    func voiceOverlayFadesOnEnterNotOnEveryStateChange() {
        let html = WebChatPage.html(toolVersion: nil)
        // The fade-in is gated to an .enter class set only on entry, so the whole overlay does not
        // flash transparent on each listening→thinking→speaking transition.
        #expect(html.contains(".voicewrap.enter{ animation:eshfade"))
        #expect(html.contains("S._voiceFadeIn"))
        // Base .voicewrap must NOT carry the animation itself.
        #expect(html.contains(".voicewrap{ position:absolute; inset:0; background:var(--paper); display:flex; flex-direction:column; z-index:60; }"))
    }

    @Test
    func micLongPressRecordsAPlayableAudioAttachment() {
        let html = WebChatPage.html(toolVersion: nil)
        // Hold the mic to record; the clip attaches and plays in the composer and in the chat.
        #expect(html.contains("function wireMicHold("))
        #expect(html.contains("function startAudioRecording("))
        #expect(html.contains("hold to record audio"))
        #expect(html.contains("release to attach"))
        // Audio attachments render a custom on-brand player (no native <audio controls>).
        #expect(html.contains("function audioPlayer("))
        #expect(html.contains("function wireAudioPlayers("))
        #expect(html.contains("class=\"aplayer\""))
    }

    @Test
    func audioOnlyMessageIsTranscribedNotSentEmpty() {
        let html = WebChatPage.html(toolVersion: nil)
        // A recorded audio with no text is transcribed (so the model gets text); if that yields nothing,
        // the message is kept playable but no empty conversation is sent to the model.
        #expect(html.contains("function transcribeAtts("))
        #expect(html.contains("atts.some(a=>a.kind==='audio')"))
    }

    @Test
    func composerHasAScrimAndSmallScreensOverlayTheSidebar() {
        let html = WebChatPage.html(toolVersion: nil)
        // A gradient scrim fades the thread out as it scrolls under the composer.
        #expect(html.contains(".composer::before"))
        #expect(html.contains("linear-gradient(to bottom, rgba(251,250,248,0)"))
        // On small screens the sidebar overlays the chat (absolute + backdrop), and the settings
        // category list becomes a horizontal scroller.
        #expect(html.contains("@media(max-width:768px)"))
        #expect(html.contains("sbackdrop"))
        #expect(html.contains("settingsbody"))
        #expect(html.contains("window.innerWidth<=768"))
    }

    @Test
    func chatRendersRicherMarkdownWithSelfContainedHighlighting() {
        let html = WebChatPage.html(toolVersion: nil)
        // Block markdown (headings, lists, blockquotes) + a small in-house highlighter — no CDN/deps.
        #expect(html.contains("function mdBlocks("))
        #expect(html.contains("function highlight("))
        #expect(html.contains("class=\"mdh"))
        #expect(html.contains("class=\"mdul\""))
        #expect(html.contains("hlk"))   // keyword token class
        // Must stay self-contained (the existing self-contained test also guards this).
        #expect(html.contains("shiki") == false)
        #expect(html.contains("cdn.") == false)
    }

    @Test
    func chatLogIsReusedAcrossPopoverTogglesToAvoidFlicker() {
        let html = WebChatPage.html(toolVersion: nil)
        // Opening/closing a popover must not rebuild + re-parse the whole thread (which flashed).
        #expect(html.contains("function logSig("))
        #expect(html.contains("S._logNode && S._logSig===sig"))
    }

    @Test
    func messageQueueUsesConventionalKeysAndADiscoverableAction() {
        let html = WebChatPage.html(toolVersion: nil)
        // Conventional chat keys are preserved; queue is Option+Enter or Cmd/Ctrl+Shift+Enter.
        #expect(html.contains("if(e.altKey || ((e.metaKey||e.ctrlKey)&&e.shiftKey)){ e.preventDefault(); enqueueDraft()"))
        #expect(html.contains("if(e.shiftKey) return;"))                 // Shift+Enter → new line
        #expect(html.contains("(e.metaKey||e.ctrlKey)&&!e.shiftKey){ e.preventDefault(); send()"))  // Cmd/Ctrl+Enter → send
        // A discoverable queue button appears while generating.
        #expect(html.contains("id=\"queuebtn\""))
        #expect(html.contains("queueDraft"))
        // IME/composition safety: Enter during composition must not send or queue.
        #expect(html.contains("if(e.isComposing || e.keyCode===229 || S._composing) return;"))
        #expect(html.contains("oncompositionstart"))
        #expect(html.contains("oncompositionend"))
        // The queue machinery is intact.
        #expect(html.contains("function enqueueDraft("))
        #expect(html.contains("function maybeSendQueue("))
        #expect(html.contains("function renderQueue("))
        #expect(html.contains("S._stopQueue"))
        // Per-conversation queue: a queued message runs in the chat it was written in, never the open one.
        #expect(html.contains("c.queue=c.queue||[]; c.queue.push({text:t, atts:S.pendingAtts.slice()})"))
        #expect(html.contains("send({chatId:chatId, text:item.text, atts:item.atts})"))
        #expect(html.contains("S.genChatId=c.id"))
        // Streaming UI is bound to the generating chat.
        #expect(html.contains("S.streaming&&S.genChatId===S.current"))
    }

    @Test
    func chatsHaveRightClickRenameAndDelete() {
        let html = WebChatPage.html(toolVersion: nil)
        #expect(html.contains("addEventListener('contextmenu'"))
        #expect(html.contains("function renderChatMenu("))
        #expect(html.contains("renameChat"))
        #expect(html.contains("deleteChat"))
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

    // Soak (rc.5): assistant replies never auto-speak — a per-message "read aloud"
    // button is the only speech trigger in text chat.
    @Test
    func readAloudIsManualPerMessageNotAutomatic() {
        let html = WebChatPage.html(toolVersion: nil)
        // Per-message speak button in the assistant footer, using an inline SVG (no emoji).
        #expect(html.contains("data-act=\"speakMsg\""))
        #expect(html.contains("asstfoot"))
        #expect(html.contains("speaker:'<svg"))
        // No automatic text-to-speech: the old auto-read toggle and its per-response
        // call are gone (they surprised users and drove repeated TTS model loads).
        #expect(html.contains("autoTts") == false)
        #expect(html.contains("toggleTts") == false)
        #expect(html.contains("Read responses aloud") == false)
        #expect(html.contains("Text chat never auto-speaks"))
        // Read-aloud lifecycle is leak-safe: one audio at a time, object URLs revoked.
        #expect(html.contains("function stopSpeak()"))
        #expect(html.contains("async function speakMessage("))
        #expect(html.contains("URL.revokeObjectURL"))
        // The speak button's state is part of the log signature so it repaints
        // (idle → loading → playing) despite the message-list DOM being reused.
        #expect(html.contains("const speakPart="))
    }

    // Soak (rc.5): popovers/menus must not re-play their entrance animation on the
    // full re-renders that happen while they stay open (e.g. streaming start/end) —
    // that read as the menu "jumping".
    @Test
    func popoversAnimateOnlyOnOpenTransition() {
        let html = WebChatPage.html(toolVersion: nil)
        #expect(html.contains("function popAnimPass()"))
        #expect(html.contains(".pop.opening{ animation:eshpop"))
        // The bare .pop no longer carries the animation unconditionally.
        #expect(html.contains(".pop{ animation:eshpop") == false)
        // Engine panel centers with margin, not transform, so the entrance animation
        // (which animates transform to none) can't shift it sideways.
        #expect(html.contains("margin-left:-170px"))
    }

    // Soak (rc.7): the reasoning block must not blink while a reply streams — the
    // streaming subtree is patched in place (reasoning text + answer HTML) instead of
    // being re-created every tick, which replayed the <details> fade/pulse animations.
    @Test
    func streamingBubbleIsPatchedInPlaceSoReasoningDoesNotBlink() {
        let html = WebChatPage.html(toolVersion: nil)
        #expect(html.contains("function patchStream("))
        // throttleRender now patches rather than replacing the whole subtree each tick.
        #expect(html.contains("if(S.streaming&&sw){ patchStream(sw);"))
        // In-place text updates, not a full innerHTML rebuild every tick.
        #expect(html.contains("if(rc) rc.textContent=s.reason"))
        #expect(html.contains("const sameStruct="))
    }

    // Soak (rc.5): the streaming cursor sits inline at the end of the last block,
    // not dropped onto its own line below the text.
    @Test
    func streamingCaretIsInlineNotOnItsOwnLine() {
        let html = WebChatPage.html(toolVersion: nil)
        #expect(html.contains(".asttext.streaming>:last-child::after"))
        #expect(html.contains("class=\"asttext streaming\""))
        // The old trailing caret span (which dropped below block content) is gone.
        #expect(html.contains("md(s.answer)}<span class=\\\"caret\\\">") == false)
    }

    // Soak (rc.5): chats can be organized into folders — collapsible, renamable,
    // deletable, and drop targets for drag-and-drop.
    @Test
    func chatsCanBeOrganizedIntoFolders() {
        let html = WebChatPage.html(toolVersion: nil)
        #expect(html.contains("function loadFolders()"))
        #expect(html.contains("function saveFolders()"))
        #expect(html.contains("data-act=\"newFolder\""))
        #expect(html.contains("data-act=\"toggleFolder\""))
        #expect(html.contains("renameFolder"))
        #expect(html.contains("deleteFolder"))
        #expect(html.contains("function moveChatToFolder("))
        // Chats are draggable and folders/Recent are drop targets.
        #expect(html.contains("draggable=\"true\""))
        #expect(html.contains("data-drop-root"))
        #expect(html.contains("dropover"))
        // Deleting a folder returns its chats to Recent (doesn't delete them).
        #expect(html.contains("delete ch.folderId"))
    }

    // Soak (rc.5): renaming a chat/folder edits the title inline (focused input,
    // Enter to commit) rather than through a popup prompt().
    @Test
    func renameIsInlineNotAPopup() {
        let html = WebChatPage.html(toolVersion: nil)
        #expect(html.contains("function startRename("))
        #expect(html.contains("function commitRename()"))
        #expect(html.contains("id=\"renameinput\""))
        #expect(html.contains("function wireSidebar()"))
        // No more prompt()-based chat rename.
        #expect(html.contains("prompt('Rename chat'") == false)
    }

    // Soak (rc.5): user message bubbles are compact (reduced vertical padding).
    @Test
    func userBubblesAreCompact() {
        let html = WebChatPage.html(toolVersion: nil)
        #expect(html.contains(".userbubble{ background:var(--userbubble); border-radius:13px; padding:6px 13px;"))
        // The bubble renders md(), so the inner paragraph must not keep the browser-default ~14px
        // top/bottom margins (which inflated the bubble height).
        #expect(html.contains(".userbubble .mdp{ margin:0;"))
    }

    // Soak (rc.5): a model that fails to load (e.g. files missing) streams an
    // "[error] …" reply; it renders as the friendly error card, not a normal
    // message with a read-aloud button.
    @Test
    func modelLoadErrorsRenderAsAFriendlyCard() {
        let html = WebChatPage.html(toolVersion: nil)
        #expect(html.contains("rawAns.match(/^\\[error\\]"))
        #expect(html.contains("This model isn’t available"))
        #expect(html.contains("install path does not exist"))
        // Uses the isError card path (with Try again / Continue with Auto).
        #expect(html.contains("isError:true, model:shortModel(resolved||S.modelSel), lastUser:text"))
    }

    // Soak (rc.5): a sent audio clip shows a "Transcribing…" indicator, then its
    // transcription as a caption (not as text the user typed); the model still
    // receives the transcript.
    @Test
    func audioTranscriptionShowsAsACaptionWithIndicator() {
        let html = WebChatPage.html(toolVersion: nil)
        #expect(html.contains("userMsg.transcribing=true"))
        #expect(html.contains("Transcribing…"))
        #expect(html.contains("class=\"transcap"))
        #expect(html.contains("userMsg.transcript=tr"))
        // attText feeds the transcript to the model.
        #expect(html.contains("if(m.transcript&&m.transcript.trim()) s+=m.transcript.trim();"))
    }

    // Soak (rc.5): read-aloud shows a mini player above the composer — loading,
    // play/pause, progress, and stop.
    @Test
    func readAloudHasAMiniPlayerAboveTheComposer() {
        let html = WebChatPage.html(toolVersion: nil)
        #expect(html.contains("function renderMiniPlayer()"))
        #expect(html.contains("class=\"miniplayer\""))
        #expect(html.contains("data-act=\"speakToggle\""))
        #expect(html.contains("data-act=\"speakStop\""))
        #expect(html.contains("id=\"mpfill\""))
        #expect(html.contains("function updateMiniProgress("))
        // It's rendered as part of the composer.
        #expect(html.contains("${renderMiniPlayer()}<div class=\"cbox\">"))
    }

    // Soak: assistant replies stored before the runaway fix (or from a gated/mismatched model) can
    // hold leaked chat/EOS special tokens and hallucinated extra turns. The display sanitizer must be
    // wired into both the render path and the read-aloud path so history never shows/speaks them, while
    // legitimate <think> reasoning is left for splitThink to parse.
    @Test
    func storedRepliesAreSanitizedForDisplayAndSpeech() {
        let html = WebChatPage.html(toolVersion: nil)
        #expect(html.contains("function sanitizeModelText("))
        #expect(html.contains("_DISPLAY_STOP_MARKERS"))
        // Renders through the sanitizer.
        #expect(html.contains("splitThink(sanitizeModelText(m.content)"))
        // Read-aloud speaks the sanitized text.
        #expect(html.contains("const clean=sanitizeModelText(m.content);"))
        // <think>/</think> are NOT stripped (reasoning must still parse).
        #expect(!html.contains("_DISPLAY_STOP_MARKERS=['<think>"))
    }

    // Soak: recent-chat rows must have symmetric top/bottom padding — the row is flex-centered and the
    // title lives in a .clabel span (so ellipsis works while the text stays vertically centered).
    @Test
    func sidebarChatRowsAreVerticallyCentered() {
        let html = WebChatPage.html(toolVersion: nil)
        #expect(html.contains("class=\"clabel\">${esch(ch.title||'New chat')}</span>"))
        #expect(html.contains(".chatitem{ display:flex; align-items:center;"))
        #expect(html.contains(".chatitem .clabel{"))
    }

    // Soak: the model-detail modal's Install/✕ buttons are dispatched by the delegated click listener on
    // `document`, so the modal must NOT blanket-stopPropagation (that swallowed the clicks → "Install
    // does nothing"). The backdrop closes only when the overlay itself is the click target.
    @Test
    func modalDoesNotSwallowDataActClicks() {
        let html = WebChatPage.html(toolVersion: nil)
        #expect(!html.contains("md_.onclick=e=>e.stopPropagation()"))   // the bug — must be gone
        #expect(html.contains("on:(e)=>{ if(e.target===ov)"))            // backdrop-only close
        #expect(html.contains("data-act=\"doInstall\""))
    }

    // UCMR Stage 2: assistant messages render typed capability artifacts (image/SVG inline via
    // /v1/artifacts, download; other kinds as a file pill) via a /v1/execute client.
    @Test
    func rendersTypedCapabilityArtifacts() {
        let html = WebChatPage.html(toolVersion: nil)
        #expect(html.contains("function artifactHTML("))
        #expect(html.contains("/v1/artifacts/"))
        #expect(html.contains("async function execCapability("))
        #expect(html.contains("'/v1/execute'"))
        // Wired into the assistant message renderer.
        #expect(html.contains("m.artifacts && m.artifacts.length"))
        #expect(html.contains("class=\"astimg\""))
    }

    // UCMR Stage 3: a plain image-generation request routes to image.generate (no manual runtime pick),
    // shows generation progress, renders the artifact, and exposes "Why this execution plan?".
    @Test
    func capabilityRouterIsWiredIntoTheChatFlow() {
        let html = WebChatPage.html(toolVersion: nil)
        #expect(html.contains("async function routeCapability("))
        #expect(html.contains("'/v1/route'"))
        #expect(html.contains("async function handleRoute("))
        #expect(html.contains("handleRoute(c, text, atts)"))     // routed inside send()
        #expect(html.contains("installRequired"))
        #expect(html.contains("Install & continue"))             // install-and-resume card
        #expect(html.contains("/v1/route/resume"))
        #expect(html.contains("function planInspectorHTML("))
        #expect(html.contains("Why this execution plan?"))
    }

    // Soak: install progress stays visible from the main chat view (not just the model browser) via a
    // top-bar indicator; polling continues regardless of the active view.
    @Test
    func installProgressShowsInTheChatTopBar() {
        let html = WebChatPage.html(toolVersion: nil)
        #expect(html.contains("function installIndicator()"))
        #expect(html.contains("${installIndicator()}"))
        #expect(html.contains("class=\"installchip\""))
        #expect(html.contains("function activeInstalls()"))
    }
}
