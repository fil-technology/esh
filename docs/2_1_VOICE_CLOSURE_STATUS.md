# Voice 2.1 — Technical Closure Status (PR #8, DRAFT)

**Branch:** `voice-2.1-runtime-core` · **Date:** 2026-09-06 · **Machine:** Apple Silicon, 32 GB
Main already merged (`42c813f`); tree reconciled, no merge fallout. PR #8 stays **DRAFT** until technical
closure passes; **not merged**.

Verification stacks: fast voice stack = `llama-3.2-3b-instruct-4bit` (LLM) + `Soprano-80M-bf16` (TTS) +
`parakeet-tdt-0.6b-v2` (STT). All models cached on managed SSD (`/Volumes/Sviat SSD/esh-models`).

| # | Gate | Status | Evidence |
|---|------|--------|----------|
| 0 | Reconcile + baseline suite | ✅ | main merged; 27/27 voice core tests pass |
| 1 | Streaming / chunked TTS | ✅ | phrase-streaming shipped; sub-phrase streaming blocked by TTSMLX `@MainActor` (proven) |
| 2 | Shipping-path latency | ✅ | real WS path 1961 ms warm avg (<2.5 s); Voice Auto wired into serve |
| 3 | Voice Install-and-Resume | ❌ | not wired to the realtime voice path — see below |
| 4 | Forced-offline full Voice | ✅ | HF-offline run, 3 turns, no network, all-local |
| 5 | EN / RU / HE structural fixtures | ◑ | EN verified; RU/HE classified (unsupported on current stack) |
| 6 | Disconnect / cancellation matrix | ✅ | 15/15 transport tests |
| 7 | Voice doctor / observability | ✅ | `esh doctor` voice section + `--json` + test |
| 8 | Browser verification (`/voice`) | ✅ | page loads/renders, permission-denied UX graceful, no JS errors; behaviors confirmed via source + transport tests |
| 9 | Packaged-path verification | ◑ | serve starts, WS listens, Voice Auto + managed models resolve; package smoke pending |
| 10 | Regression + CI | ◑ | 117 deterministic tests (15 suites) green incl. voice/routing/capability/doctor; full model/package suite pending |

Legend: ✅ pass · ◑ partial/honest-classified · ⏳ pending.

---

## Gate 4 — Forced-offline full Voice proof ✅

Ran `voice-ws-bench` (real WS server, real STT/LLM/TTS) with `HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1`
(any Hugging Face fetch would *error*), 3 turns:

```
turn STT     TTFT    TTSaud  →playable  freeMB
 1   4132ms  7160ms  2454ms  13746ms    10962   (cold)
 2   1034ms   365ms  2650ms   4049ms    10764
 3    126ms   513ms  2898ms   3536ms    10613
```

- VAD local (server EnergyVAD) ✅ · STT local (Parakeet) ✅ · LLM local (MLX) ✅ · TTS local (Soprano) ✅
- **No** `download`/`http`/`fetch`/`network` lines in the log; models loaded from the SSD cache only.
- Turns 2–3 (subsequent sessions) succeeded → no cache duplication, next session works.

## Gate 5 — EN / RU / HE structural fixtures ◑ (EN verified; RU/HE honestly classified)

**EN — verified end-to-end** (`voice-turn`, real STT→LLM→TTS):

```
[heard] Hello, John Z. How are you today? ...        (English transcript, correct)
[reply] I'm doing well, thanks for asking. ...        (coherent English reply)
reply audio: 1.47 s valid WAV (first phrase; buffered per-phrase)
provider/model: STT parakeet-tdt-0.6b-v2 · LLM llama-3.2-3b-4bit · TTS Soprano-80M
```

**RU — not supported on the current installed stack (honest classification):**
- STT `parakeet-tdt-0.6b-v2` is **English-only** → Russian speech cannot be transcribed correctly.
- No installed TTS speaks Russian. The catalog's `Qwen3-TTS-12Hz-0.6B` *does* list Russian, but it is **not
  installed**.
- Path to support: install a multilingual STT (e.g. Whisper) **and** `Qwen3-TTS`; then re-run this fixture.

**HE (Hebrew) — unsupported (honest classification):**
- English-only STT, and **no TTS model in the esh catalog lists Hebrew at all** (catalog TTS languages:
  EN, ES, FR, DE, IT, PT, NL, PL, TR, RU, JA, KO, ZH, AR, HI — Hebrew absent).
- Hebrew requires both a Hebrew-capable STT and TTS that esh does not currently offer. Classified
  **unsupported**, not silently degraded.

No pronunciation-quality claims are made (requires human acoustic acceptance — the user's manual gate).

---

## Gate 8 — Browser `/voice` ✅ (structural)

Served at `GET /voice` (HTTP 200, 7.4 KB, self-contained). Loaded in a headless browser:
- Page renders: mic orb, "Ready" state, Start/End buttons, on-device hint, empty transcript log.
- **Permission-denied UX:** clicking Start with no microphone shows "Microphone permission is required for
  voice." (red), the UI stays healthy and recoverable (Start re-enabled), and there are **no console errors**.
- Client behaviors verified in page source + by the 15/15 headless transport tests (same server path): WS
  connect, `session.state` transitions, transcript render, ordered binary playback queue, `playback.cancelled`
  → flush, `if(turn<curTurn) return` stale-turn drop, reconnect via Start.
- Live mic-driven capture/playback is the user's physical acoustic acceptance gate (not scriptable headless).

## Gate 3 — Voice Install-and-Resume ❌ (genuine gap — realtime path not wired)

Investigated thoroughly. The Capability Router **does** have a full Install-and-Resume implementation
(`Sources/EshCore/Routing/InstallAndResume.swift`, `InstallRequirement`, `IntentResolver`, tested by
`IntentResolverTests`/`DeterministicIntentRouterTests`). **But the realtime voice path does not use it:**

- `VoiceWebSocketServer` / `VoiceSessionOrchestrator` construct `SpeechRuntimeTranscriber` /
  `LanguageResponder` / `BufferedTTSSpeaker` directly and assume the models are present. A missing STT/LLM/TTS
  surfaces as a mid-turn `session.error`, **not** an `InstallRequirement → combined Voice Fit → install →
  resume-at-safe-boundary` flow.
- `grep` confirms zero references to `InstallAndResume` / `InstallRequirement` under `Sources/EshCore/Voice/`.

**This gate requires net-new realtime behavior**, not a closure fix: a voice preflight on session start that
resolves STT+LLM+TTS, computes combined Voice Fit, and — when a component is missing — emits a new typed wire
event carrying the requirement + Fit, holds at a safe boundary, drives the managed-SSD install, then resumes.
That touches the WS protocol (a new event), the orchestrator, and the server. It is deliberately **not**
bolted on here without explicit buy-in, since the release plan calls for stability on the realtime path.

## Remaining

- **Gate 3 — Voice Install-and-Resume:** implement the realtime preflight + install-required event + resume
  (scoped above). Blocks the technical-closure stop condition.
- **Gate 9 — Packaged-path (partial):** serve start + WS listen + Voice Auto + managed-model resolution
  observed; remaining: `scripts/smoke-test-package.sh` against a packaged/notarized build, dev-path leak scan.
- **Gate 10 — Regression + CI (partial):** voice + doctor suites 41/41 green; remaining: full Swift suite +
  Python tests + package smoke + CI.

## Honest stop-condition assessment

The technical-closure stop line (`TECHNICAL VOICE GATES PASS`) is **not yet reachable**: Gate 3 is a real
unimplemented feature on the realtime path, and Gates 9/10 are partial. Gates 1, 2, 4, 5(EN), 6, 7, 8 pass
with real evidence; RU/HE are honestly classified unsupported on the current stack.
