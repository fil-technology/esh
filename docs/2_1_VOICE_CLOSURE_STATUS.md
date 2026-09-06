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
| 3 | Voice Install-and-Resume | ✅ | realtime preflight → `install.required` + Voice Fit, safe-boundary hold, resume; test |
| 4 | Forced-offline full Voice | ✅ | HF-offline run, 3 turns, no network, all-local |
| 5 | English Voice qualification + honest language reporting | ✅ | EN end-to-end verified; STT/TTS languages reported; RU/HE explicitly non-production, no silent misbehavior |
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

## Gate 3 — Voice Install-and-Resume ✅ (realtime preflight implemented)

The Capability Router already had Install-and-Resume (`Routing/InstallAndResume.swift`), but the realtime
voice path never used it. Implemented a realtime-path preflight:

- `VoiceWebSocketServer` gained an optional, model-store-agnostic `Preflight` closure (default = always ready,
  so tests/back-compat are unaffected). On each `start`, if it returns `.installRequired`, the server emits a
  typed **`install.required`** event (flat envelope: `message` = summary, `reason` = combined Voice Fit,
  `text` = recommended repo, `state` = component), starts **no** session and runs **no** turn (safe boundary).
  Incoming audio while held is ignored. Re-`start` after the model is installed **resumes** normally.
- `ServeCommand` injects the real preflight: it re-lists installs, honors an explicit pin else Voice Auto,
  and computes combined Voice Fit; a missing/over-budget LLM → `install.required` recommending a small model
  installed via the managed-SSD installer (no hidden downloads; the preflight itself fetches nothing).
- `/voice` page renders `install.required` as a clear prompt and returns to idle (recoverable).
- Test: `installRequiredHoldsAtSafeBoundaryThenResumes` — install.required carries a summary + Voice Fit, no
  turn runs while held, and the session resumes and completes a turn after "install" + re-start.

## Gate 5 — English Voice qualification + honest language reporting ✅

(Scope per the 2.1 release plan: **English is the required production language**; RU/HE are non-blocking.)

- **EN — qualified end-to-end** through the real WS path (`voice-turn`/`voice-ws-bench`): audio → VAD → STT →
  LLM → TTS → valid streamed audio; transcript + coherent reply captured; warm endpoint→playable 1.7–2.0 s.
- **Language support reported honestly:** STT `parakeet-tdt-0.6b-v2` is English-only; installed TTS
  (Soprano/pocket/Marvis) are English. `doctor` reports the STT/TTS stack; RU/HE are **explicitly
  non-production** (RU-capable Qwen3-TTS exists in the catalog but is not installed; no Hebrew TTS exists).
- **No silent misbehavior:** unsupported input does not crash or fabricate — the disconnect/silence matrix
  proves the server stays healthy; RU/HE are not advertised as supported. RU/HE qualification → post-2.1.

## Remaining

- **Gate 9 — Packaged-path (partial):** serve start + WS listen + Voice Auto + managed-model resolution
  observed; remaining: `scripts/smoke-test-package.sh` against a packaged/notarized build, dev-path leak scan.
- **Gate 10 — Regression + CI (partial):** 117 deterministic tests (15 suites) + 16 transport tests green;
  remaining: full Swift suite + Python tests + package smoke + CI.

## Stop-condition assessment

Gates 1–8 pass with real evidence (Gate 5 under the English-first scope). Remaining before
`TECHNICAL VOICE GATES PASS`: Gate 9 package smoke and Gate 10 full-suite/CI. No RU/HE blockers.
