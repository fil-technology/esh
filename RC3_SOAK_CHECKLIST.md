# RC3 soak checklist

Running log of issues found while soaking the **untagged rc.3 tree** (rc.2 = `v2.0.0-rc.2` stays
immutable). rc.3 is a **bug-fix / polish freeze** (+ one approved feature exception: message queue).
Tag `v2.0.0-rc.3` only on explicit approval, on the exact green commit.

Legend — Pkg = packaged validation required at tag time.

| # | Issue | Reproduction | Root cause | Fix | Commit | Browser✓ | Auto cov | Pkg |
|---|-------|--------------|-----------|-----|--------|:---:|:---:|:---:|
| 1 | Picker didn't match design; mic looked orphaned in composer | Open chat; picker was in top-right header, mic floated | Model picker belonged **in** the composer as a chip; header should be minimal | Moved picker into composer as `Auto ▾` chip; header = sidebar+brand+settings | 4438247 | ✓ | ✓ | yes |
| 2 | Composer lost focus after sending | Send a message; textarea blurred | Trailing `throttleRender` rebuilt composer ~40ms after final render | Cancel pending throttle at stream end; re-arm `focusInput` | 433e135 | ✓ | ✓ | yes |
| 3 | Voice not hands-free (had to tap to end) | Enter voice; had to tap the circle | No end-of-speech detection | Web Audio VAD auto-ends listening on a pause | 433e135 | ✓ | env-limited (mic) | yes |
| 4 | Model/effort chips floated mid-bar (not right-aligned) | Composer with chips | `.cbox` was a flex **row** with one content-sized child | Make `.cbox` a column so the input fills and chips right-align | e5f8970 | ✓ | ✓ | yes |
| 5 | Popovers didn't close on re-click / outside click | Open picker/effort; click chip again or elsewhere | Toggles always re-opened; no outside-click handler | Real toggles + outside-click close | e5f8970 | ✓ | ✓ | yes |
| 6 | Effort slider click-only (no drag) | Try to drag the knob | No pointer-drag handler | Pointer drag with live knob preview + commit on release | e5f8970 | ✓ | ✓ | yes |
| 7 | Focus not returned after changing effort/model | Pick a model/effort | `focusInput` not re-armed on those actions | Re-arm focus on pick + popover close | 284666a | ✓ | ✓ | yes |
| 8 | Attachment layout wrong (inline, not stacked) | Attach a file | Same row/column bug as #4 | Fixed by the composer column change | 284666a | ✓ | ✓ | yes |
| 9 | Sent attachment not shown in chat / not sent to model | Attach a `.txt`, send | Bubble rendered only image/audio; content never sent | Render doc/text pill; decode + append text to model request | 284666a | ✓ | ✓ | yes |
| 10 | Whole UI blinked while voice was speaking | Voice reply | `render()` per word rebuilt the whole app | Update only `#vanswer` node during reveal | 284666a | env-limited (mic) | ✓ | yes |
| 11 | Voice error stage looked bare | Trigger voice with server down | Minimal error card | Restyled: icon, copy, primary/secondary buttons | 284666a | ✓ | — | yes |
| 12 | Couldn't choose voice model/voice/language | Settings → Voice | Static labels, not wired | Real dropdowns from `/v1/audio/models` (TTS model/voice/language) + Parakeet/custom STT | e22f35a | ✓ | ✓ | yes |
| 13 | Voice "takes too long to speak out" | Voice reply latency | Non-streaming reply + full-reply TTS (≈gen+full-synth) | Stream reply; synthesize+play sentence-by-sentence | d429f0c | env-limited (mic) | ✓ | yes |
| 14 | No way to rename/delete chats | Sidebar | Missing | Right-click → Rename / Delete menu | d429f0c | ✓ | ✓ | no |
| 15 | (Approved feature exception) Message queue | Line up follow-ups | New feature | Queue via **Option+Enter / Cmd+Shift+Enter** + a discoverable queue button while generating; conventional keys preserved (Enter=send, Shift+Enter=newline, Cmd+Enter=send); pills; auto-send in order; Stop doesn't auto-continue | 529d559, 5ec6fc8 | ✓ | ✓ | yes |
| 16 | Voice overlay flashed transparent on each state change | Enter voice; state changes | `.voicewrap` replayed its fade on every render | Fade gated to an `.enter` class (entry only) | e4434ff | ✓ | ✓ | yes |
| 17 | (Approved feature) Record audio by long-pressing the mic | Hold the mic button | New feature | Hold=record → playable audio attachment; tap=voice mode; sent clip plays in chat | e4434ff | ✓ | env-limited (mic) | yes |
| 18 | Native `<audio controls>` player (off-brand) | Attach/send audio | Used the system player | Custom on-brand player (play/pause, progress, seek, mono time) in composer + bubble | b25e356 | ✓ | ✓ | yes |
| 19 | Audio-only send → "Cannot apply chat template to an empty conversation" | Record audio, send with no text | Empty content sent to the model | Transcribe the clip (STT) for the model; if empty, keep it playable and don't call the model | b25e356 | ✓ | ✓ (logic) | yes |
| 20 | Whole view flickered when opening/closing a popover | Open/close the model picker over a long thread | Every toggle rebuilt + re-parsed the whole thread (+scroll-jump) | Reuse the log DOM when the conversation is unchanged (`logSig`) | b25e356 | ✓ | ✓ | yes |
| 21 | Code blocks/markdown were plain and unstyled | Ask for code | Minimal in-house markdown; no highlighting | Richer block markdown + a self-contained syntax highlighter (warm palette) — **Shiki not usable** (self-contained/no-CDN) | 622f8e8 | ✓ | ✓ | yes |
| 22 | Composer had a hard edge; thread didn't fade under it | Scroll a long thread | No scrim | Transparent→paper gradient scrim above the composer (`.composer::before`) | 4ff100d | ✓ | ✓ | yes |
| 23 | Small screens squeezed the chat with the sidebar | Narrow window | Sidebar/settings were fixed columns | ≤768px: sidebar overlays **full-width** (toggle-opened, starts collapsed; topbar toggle closes it); settings categories become a horizontal scroller; desktop unchanged | 4ff100d, 5ec6fc8 | ✓ (375px) | ✓ | yes |
| 24 | Enter could send while composing (IME) | CJK/IME composition | keydown didn't check composition | Guard Enter on `isComposing`/keyCode 229/compositionstart-end flag before any send/queue | afe1cdf | ✓ | ✓ | yes |
| 25 | **Queued message could run in the wrong conversation** | Queue in A, switch to B, A finishes | `S.queue` global; `maybeSendQueue()` sent via `cur()` | Per-conversation queue (`c.queue`); `send(queued)` routes to the origin chat; generation bound to `S.genChatId` (streaming UI too) | b0ea0b0 | ✓ (real inference: ran in A, B empty) | ✓ | yes |
| — | Warm-TTS (per-call model reload) | Voice latency | v0.7.0+ of TTSMLX already caches (`prepareModel`); esh only needs one long-lived synthesizer + the fork dep | **Correct fix identified, build env-blocked.** My "TTSMLX v0.8.0 broken" note was WRONG — `TTSModelRegistry` is a `public` API of the **fork** `fil-technology/mlx-audio-swift@0.1.7-tts.1` (which v0.8.0 pins). esh's root pin of **upstream** `Blaizzy/mlx-audio-swift` (same identity) overrode it. **Fix:** point esh's dep at the fork — verified it **resolves** cleanly (`0.1.7-tts.1`, revision `bb5cda2a`, has the symbol). **Blocked on build env:** `.build` is on the ExFAT SSD (relocated when internal disk hit 100%); ExFAT `._pack` AppleDouble files corrupt git for the new clones (`non-monotonic index`), and internal disk (~7.5 GB free) is too small to host the 11 GB `.build` on APFS. esh reverted to 0.3.3, builds clean. Needs ~15 GB free internal (APFS) to build/verify, then the small esh change (long-lived synthesizer). Streamed sentence-pipeline (#13) is the shipped esh-local win. | _env-blocked (disk)_ | — | — | n/a |

## rc.5 — web chat soak (found while soaking rc.4)

| # | Issue | Reproduction | Root cause | Fix | Browser✓ | Auto cov | Pkg |
|---|-------|--------------|-----------|-----|:---:|:---:|:---:|
| 26 | Popovers/menus "jump" while a reply streams | Open Engine (or model) popover, send a message | `.pop` carried the `eshpop` entrance animation unconditionally, so it re-played on every full re-render (streaming start/end), not just on open; the Engine panel also centered via `transform:translateX(-50%)`, which the animation (transform→none) fought | Animate only on the open transition (`popAnimPass` adds `.opening`); center the Engine panel with `margin-left` instead of transform | ✓ (rect stable across re-renders; `opening` only on open) | ✓ | yes |
| 27 | Replies auto-spoke as audio; wanted a manual control | Send any message with "Read responses aloud" on | Text chat auto-called `speak()` on every response | Removed auto-TTS + the toggle; added a per-message **read-aloud button** (idle → loading → playing) under each assistant reply | ✓ (real inference: 0 TTS loads; manual click → valid WAV, plays, resets) | ✓ | yes |
| 28 | TTS drove memory growth / looked like a loop | Long/many auto-spoken replies | Auto-TTS reloaded the TTS model per response (per sentence on long replies — warm-TTS still deferred) + `speak()` never revoked its object URL | Auto-TTS removed (main trigger gone); manual speak is one bounded synth per click; single audio + `revokeObjectURL` on end/stop (leak fixed) | ✓ (0 loads on text send; one bounded synth per manual click) | ✓ (logic) | yes |
| — | "User message looks too big" (1st report) | Screenshot 2 (zoom crop) | Text was already 14px; but on re-report the **bubble padding** was genuinely chunky | Reduced `.userbubble` padding `10px 14px`→`6px 13px`, line-height 1.5→1.45, radius 14→13 (see #29) | ✓ | ✓ (`userBubblesAreCompact`) | yes |
| 29 | User message bubbles too tall | Send short messages | Vertical padding + line-height too large | Compact `.userbubble`; tighter `.asst` column gap 9→6 | ✓ (bubble height reduced) | ✓ | yes |
| 30 | Read-aloud icon wrong location + footer too much vertical space | Any assistant reply | Footer used a 26px button + 8px gap, icon not aligned to text | Compact `.asstfoot` (gap 4, `margin-left:-5px` to align icon with text), smaller 24px `.sbtn`/14px svg | ✓ | ✓ | yes |
| 31 | Streaming cursor on its own line | Watch any reply stream | Caret was a `<span>` after the block `md()` output, so it dropped below the last paragraph | Caret via `.asttext.streaming>:last-child::after` — inline at the end of the last block | ✓ (inline `::after` on last `<p>`) | ✓ (`streamingCaretIsInlineNotOnItsOwnLine`) | yes |
| 32 | (Feature) Folders for chats | Organize conversations | New | Collapsible folders; new-folder button; **drag chats in/out**; right-click rename/delete; delete-folder returns chats to Recent; persisted (`esh.folders.v1`) | ✓ (new folder+inline rename, move, collapse, DnD chain, persistence all verified) | ✓ (`chatsCanBeOrganizedIntoFolders`) | yes |
| 33 | Inline rename (chat + folder) | Rename from menu | Was a `prompt()` popup | Edit title **in place** — focused input, Enter commits, Escape cancels, blur commits | ✓ (auto-focus + Enter commit verified) | ✓ (`renameIsInlineNotAPopup`) | yes |
| ⚠ | **GGUF runaway generation** ("some loop") | Ask a GGUF model a question | The GGUF backend (now functional post-rc.4) generates a hallucinated multi-turn `User:/answer` transcript until the token limit — no stop sequence / chat template applied for one-shot completion. Looks like a loop; burns compute | **Open — server-side (LlamaCppBackend), NOT web.** Needs proper stop tokens / chat-template handling for `llama-completion`. Only visible now that GGUF runs instead of crashing. Flagged to user | n/a | — | **blocker for GGUF quality** |

## ✅ RELEASE BLOCKER (packaged rc.3 GGUF) — RESOLVED in rc.4

| Area | Finding / resolution |
|------|---------|
| **GGUF inference (packaged rc.3)** | **Was BROKEN on the notarized rc.3 artifact.** `share/esh/bin/llama-cli` dyld-crashed: `Library not loaded: @rpath/libllama-cli-impl.dylib`. Two-layered root cause: (1) `package-release.sh` copied only the `llama-cli` executable, **not its linked dylibs**; (2) **deeper** — modern Homebrew llama.cpp/ggml **dlopens its compute backends** (Metal/CPU/BLAS `.so`) from `/opt/homebrew/Cellar/ggml/*/libexec/` at runtime, so even with linked dylibs bundled a clean machine has **no compute backend**. Also latent: the bundled `llama-cli` is interactive-only and rejects `--no-conversation`, while esh's runtime prefers `llama-completion` (never bundled). |
| **Fix (rc.4)** | Approved approach: **build llama.cpp static from a pinned revision.** New `scripts/build-llama.sh` builds `llama-completion` from pinned **`b8660`** with `BUILD_SHARED_LIBS=OFF`, `GGML_BACKEND_DL=OFF` (backends compiled in, no dlopen), `GGML_METAL=ON` + `GGML_METAL_EMBED_LIBRARY=ON`, `LLAMA_OPENSSL=OFF`. Result links **only system frameworks** (Metal/MetalKit/Accelerate/Foundation) — no `@rpath`, no `/opt/homebrew`, no openssl, no ggml/llama dylibs. `package-release.sh` bundles it as `share/esh/bin/llama-completion` (and refuses to package a non-relocatable binary); `PackagedRuntimeBootstrap` points `ESH_LLAMA_CPP_CLI` at it; CI/release build it (cached) instead of `brew install llama.cpp`; the packaged smoke test now guards the GGUF runtime (exists + relocatable + launches). |
| **Clean-env verification (local, `env -i`)** | ✅ Runs GGUF (Llama-3.2-3B Q4_K_M) with no dyld crash; ✅ Metal active ("found device: Apple M1 Pro", embedded metal library) with **no** `load_backend … /opt/homebrew` line; ✅ correct output; ✅ **no per-call regression** — 10.8 s on the machine's *first-ever* GGUF call is a one-time Metal shader-cache compile, runs 2–3 show 0.011–0.031 s Metal load (≈ Homebrew's 0.008 s) and ~46 tok/s generation; ✅ smoke guard passes the self-contained binary and would fail a Homebrew one. Full notarized-artifact GGUF validation runs post-tag on the packaged rc.4. |
| **Not blocked (verified green on the packaged rc.3 artifact, unchanged in rc.4)** | version, Gatekeeper (Notarized Developer ID), checksum, doctor, Web + rc markers, `/v1/engine|schedule|catalog|audio/models`, **MLX inference + warm residency (0.56 s repeat)**, **STT**, **TTS** (bundled mlx_audio), **Apple Foundation Models**, install-appears-immediately, prerelease flag, stable cask untouched (0.9.7). |
| Environment-limited | Real-microphone voice (in-app browser blocks the mic — server STT/TTS + loop logic verified, actual capture needs a real browser). |

## Notes
- rc.2 already validated on the notarized artifact (version, Gatekeeper, web, engine/schedule/catalog,
  chat, **bundled mlx_audio STT+TTS**, release-channel safety). Most rc.3 changes are the web client
  (HTML/JS embedded in the binary) + the client voice pipeline → packaged validation at tag time =
  load the packaged web page + exercise the voice loop on the notarized artifact.
- Environment-limited here: the in-app browser blocks the microphone, so the full mic→STT→LLM→TTS loop
  and VAD auto-advance are verified by logic + server endpoints, not by clicking the live mic. To be
  confirmed on the packaged RC in a real browser.
- Build note: the internal disk hit 100%; `.build` was relocated to the external SSD (build artifacts
  only, no user data). CI/packaging is unaffected (fresh checkout on normal disks).

## Pre-tag sweep (run when soak is declared ready — not yet run)
Full Web Chat flow · composer focus · Enter/Shift+Enter · empty-send disabled · attachments before/after
send · text reaches model · image with a compatible model · Auto · manual model · reasoning · voice UI ·
mic loop · voice error · TTS reveal without blinking · history · new chat · settings · persistence ·
model picker · model browser · install progress/cancel · Engine Inspector · Execution Inspector · Why
this model? · external SSD status · degraded cards · responsive widths · keyboard nav · a11y · console
errors · long response/code block · Stop/cancel · server restart/reconnect · full engine test suite.
