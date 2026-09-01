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
| 15 | (Approved feature exception) Message queue | Shift+Enter to line up follow-ups | New feature | Shift+Enter enqueues; queued pills; auto-send in order; Stop doesn't auto-continue | 529d559 | ✓ | ✓ | yes |
| 16 | Voice overlay flashed transparent on each state change | Enter voice; state changes | `.voicewrap` replayed its fade on every render | Fade gated to an `.enter` class (entry only) | e4434ff | ✓ | ✓ | yes |
| 17 | (Approved feature) Record audio by long-pressing the mic | Hold the mic button | New feature | Hold=record → playable audio attachment; tap=voice mode; sent clip plays in chat | e4434ff | ✓ | env-limited (mic) | yes |
| 18 | Native `<audio controls>` player (off-brand) | Attach/send audio | Used the system player | Custom on-brand player (play/pause, progress, seek, mono time) in composer + bubble | b25e356 | ✓ | ✓ | yes |
| 19 | Audio-only send → "Cannot apply chat template to an empty conversation" | Record audio, send with no text | Empty content sent to the model | Transcribe the clip (STT) for the model; if empty, keep it playable and don't call the model | b25e356 | ✓ | ✓ (logic) | yes |
| 20 | Whole view flickered when opening/closing a popover | Open/close the model picker over a long thread | Every toggle rebuilt + re-parsed the whole thread (+scroll-jump) | Reuse the log DOM when the conversation is unchanged (`logSig`) | b25e356 | ✓ | ✓ | yes |
| 21 | Code blocks/markdown were plain and unstyled | Ask for code | Minimal in-house markdown; no highlighting | Richer block markdown + a self-contained syntax highlighter (warm palette) — **Shiki not usable** (self-contained/no-CDN) | 622f8e8 | ✓ | ✓ | yes |
| 22 | Composer had a hard edge; thread didn't fade under it | Scroll a long thread | No scrim | Transparent→paper gradient scrim above the composer (`.composer::before`) | 4ff100d | ✓ | ✓ | yes |
| 23 | Small screens squeezed the chat with the sidebar | Narrow window | Sidebar/settings were fixed columns | ≤768px: sidebar overlays with a backdrop (toggle-opened, starts collapsed); settings categories become a horizontal scroller; desktop unchanged | 4ff100d | ✓ (375px) | ✓ | yes |
| — | Warm-TTS (per-call model reload) | Voice latency | Reload lives in `mlx-audio-swift`/TTSMLX; not esh-local | **Cross-repo:** spec delivered for a TTSMLX loaded-model cache + esh dep bump; the streamed sentence-pipeline (#13) is the esh-local win | _cross-repo, pending_ | — | — | n/a |

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
