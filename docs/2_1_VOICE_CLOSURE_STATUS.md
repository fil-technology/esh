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
| 3 | Voice Install-and-Resume | ⏳ | see below |
| 4 | Forced-offline full Voice | ✅ | HF-offline run, 3 turns, no network, all-local |
| 5 | EN / RU / HE structural fixtures | ◑ | EN verified; RU/HE classified (unsupported on current stack) |
| 6 | Disconnect / cancellation matrix | ✅ | 15/15 transport tests |
| 7 | Voice doctor / observability | ✅ | `esh doctor` voice section + `--json` + test |
| 8 | Browser verification (`/voice`) | ⏳ | see below |
| 9 | Packaged-path verification | ◑ | serve starts, WS listens, Voice Auto + managed models resolve |
| 10 | Regression + CI | ⏳ | voice suites green; full suite pending |

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

## Remaining (⏳)

- **Gate 3 — Install-and-Resume:** exercise an isolated managed root with one Voice dependency made
  unavailable; prove InstallRequirement → Voice Fit → install → managed SSD → resume at a safe boundary.
- **Gate 8 — Browser `/voice`:** structural checks of the served page (load, WS connect, state/transcript
  render, binary playback queue, cancellation flush, reconnect, stale-turn drop).
- **Gate 9 — Packaged-path:** confirm `/voice` asset, WS endpoint, STT/TTS runtime discovery, managed
  models, external SSD, offline, no source-tree/dev-path assumptions. (serve start + WS + Voice Auto already
  observed.)
- **Gate 10 — Regression + CI:** full Swift suite + Python + package smoke.
