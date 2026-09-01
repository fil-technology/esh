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

## ⛔ RELEASE BLOCKER found in packaged rc.3 validation (2.0 promotion STOPPED)

| Area | Finding |
|------|---------|
| **GGUF inference (packaged)** | **BROKEN on the notarized rc.3 artifact.** `share/esh/bin/llama-cli` dyld-crashes: `Library not loaded: @rpath/libllama-cli-impl.dylib`. Root cause is two-layered: (1) `scripts/package-release.sh:36` copies only the `llama-cli` executable, **not its linked dylibs** (rpath `@loader_path/../lib` → a `share/esh/lib/` that doesn't exist); (2) **deeper** — modern Homebrew llama.cpp/ggml **dlopens its compute backends** (Metal/CPU/BLAS `.so`) from `/opt/homebrew/Cellar/ggml/*/libexec/` at runtime, so even with linked dylibs bundled, a clean machine (no Homebrew) has **no compute backend**. Verified locally that bundling the linked dylibs makes `llama-cli` load in a clean env, but the backend plugins are still pulled from Homebrew. Dev hid this by using the *system* llama-cli. |
| Requires | **rc.4** with a real llama.cpp packaging fix (bundle the ggml plugin tree + set the backend search path, OR build llama.cpp from source with static/embedded backends, OR pin a pre-plugin-split llama.cpp). `sign-release.sh` already signs all Mach-O under the payload, so added dylibs/plugins get signed automatically. |
| **Not blocked (verified green on the packaged artifact)** | version 2.0.0-rc.3, Gatekeeper (Notarized Developer ID), checksum, doctor, Web + rc.3 markers, `/v1/engine|schedule|catalog|audio/models`, **MLX inference + warm residency (0.56 s repeat)**, **STT** ("Hello from Esh."), **TTS** (valid WAV, bundled mlx_audio), **Apple Foundation Models** ("Hello."), install-appears-immediately, prerelease flag, stable cask untouched (0.9.7). |
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
