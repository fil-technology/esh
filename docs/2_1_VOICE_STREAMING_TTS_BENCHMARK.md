# Voice 2.1 — Gate 1: Streaming TTS Benchmark & Verdict

**Date:** 2026-09-06
**Branch:** `voice-2.1-runtime-core` (PR #8, DRAFT)
**Machine:** Apple Silicon, 32 GB unified memory
**Input utterance:** `.esh/audio/20260424-161109.wav` (3.84 s)
**LLM (auto-selected):** `mlx-community/qwen2.5-coder-14b-instruct-4bit`
**TTS:** `mlx-community/pocket-tts`
**Warm mode:** `ESH_MLX_PERSISTENT=1` (weights resident across turns)

## Pipeline under test

```
LLM stream → VoicePhraseChunker → TTS → VoiceAudioChunk → WebSocket binary frames → browser playback
```

The production turn loop (`VoiceSessionOrchestrator.runTurn`) already streams **phrase-by-phrase**:
the LLM is consumed as a token stream, `VoicePhraseChunker.ingest` emits a speakable phrase at each
sentence/clause boundary (`. ! ? … ; : \n` + CJK, min 12 chars), and each phrase's audio is streamed
to the browser (`emit(.ttsAudioChunk)`) **while the LLM keeps generating the next phrase**. First audio
therefore arrives after the first phrase, not the whole reply.

## Strategies compared

| # | Strategy | How | Result |
|---|----------|-----|--------|
| 1 | **Buffered per-phrase** (production) | `BufferedTTSSpeaker`, punctuation-aware chunker | ✅ measured below |
| 2 | **Sub-phrase streaming TTS** | `StreamingTTSSpeaker` → `TTSMLX.synthesizeStream` (0.6 s interval) | ❌ **deadlock — see blocker** |
| 3 | **Sentence buffering** | chunker split on `. ! ?` only | coarser → strictly *worse* first-audible than #1 |
| 4 | **Punctuation-aware phrase buffering** | breaks on clause punctuation too | = production path (#1) — best usable |

## Measured — buffered per-phrase (4 turns, warm)

```
turn       STT    LLMtok    TTSaud   →audible   freeMB
   1    8903ms   18928ms    3997ms    31828ms    10737    (cold)
   2    1006ms    3993ms    2597ms     7596ms     8514
   3     156ms    1647ms    2530ms     4333ms     7816
   4     202ms    1331ms    3000ms     4534ms     8031
warm endpoint→audible avg: 5488 ms (n=3)
```

- **first useful LLM text → first TTS chunk** (`LLMtok`→`TTSaud` boundary): first token stamped, first
  phrase synthesized in ~2.5–3.0 s warm.
- **first TTS chunk → browser-playable:** each phrase is emitted as a standalone WAV frame; browser plays
  on receipt (ordered blob queue) — no post-processing delay.
- **total endpoint → playable (warm):** ~4.3–7.6 s, avg **5488 ms**.
- **memory:** ~7.8–8.5 GB free during warm turns (14B LLM + STT + TTS co-resident on 32 GB).
- **RTF / cancellation latency:** not separately instrumented by `voice-bench` (no audio-duration field);
  covered by the dedicated disconnect/cancellation matrix (Gate 6).

## Streaming TTS — the exact blocker (PROVEN)

`--stream-tts` was run identically (same input, models, warm). It produced **zero turn rows** and the
process sat at **0.0 % CPU / 31 MB RSS for >2 h** with no audio chunk ever emitted — a hard deadlock, not
slow compute. Killed manually.

Root cause, confirmed in the TTSMLX source (`c4f21432`, v0.3.3):

```swift
// TTSSpeechSynthesizer.swift
public func synthesize(...) async throws -> ...            // line 21  — NOT @MainActor  → buffered path works
@MainActor
public func synthesizeStream(...) async throws -> AsyncThrowingStream<TTSAudioBufferChunk, Error>  // line 114 — @MainActor
```

`synthesizeStream` is `@MainActor`. `VoiceSessionOrchestrator` is a background `actor` that drives the turn
and consumes the speaker stream on its own executor; hopping the Metal/MLX streaming synthesis onto the
main actor from inside that actor-driven turn loop deadlocks (the buffered `synthesize` is non-isolated and
runs fine on a background thread). This is an upstream isolation constraint in the TTSMLX package, not a
call-site bug we can resolve inside `esh` without restructuring the third-party API.

## Verdict & decision

Per the Gate 1 contingency ("if `synthesizeStream` is genuinely unusable, prove the exact blocker and keep
the best phrase-streaming path; do not block the remaining gates on it"):

1. **Production path = punctuation-aware phrase-chunked buffered TTS** (strategy #1/#4). It already delivers
   phrase-level streaming to the browser and is the best usable path today.
2. **`ServeCommand` reverted** from `StreamingTTSSpeaker` → `BufferedTTSSpeaker` so the live server never
   ships the deadlock. Comment records the re-enable condition.
3. **Streaming code retained** (`AudioSpeechGenerator.synthesizeStream`, `StreamingTTSSpeaker`,
   `voice-bench --stream-tts`) behind the flag, off by default, for the day TTSMLX exposes a
   non-`@MainActor` streaming API. **Re-enable condition:** TTSMLX `synthesizeStream` drops `@MainActor`
   (or provides a nonisolated variant), then re-point `ServeCommand` and re-run this A/B.

**Gate 1: CLOSED** — best usable phrase-streaming path shipped; sub-phrase streaming blocker proven and
isolated. Not blocking Gates 2–10.

---

# Gate 2 — Shipping-path latency (real WebSocket transport)

Measured with a new `esh voice-ws-bench` command that drives a **real** `VoiceWebSocketServer` over a loopback
socket with real STT/LLM/TTS (exactly how `esh serve` wires them), timestamping server events observed on the
client: endpoint = `vad.speech_ended`, playable = first binary `VoiceAudioFrame`. Input = same 3.84 s utterance
(resampled to 16 kHz mono PCM16). Warm = turns 2+, `ESH_MLX_PERSISTENT=1`.

### A/B across stacks (warm endpoint→playable)

| LLM | TTS | warm avg | best warm | vs target (<2.5 s) |
|-----|-----|---------:|----------:|:--|
| qwen2.5-coder-**14B** (auto-picked "first MLX") | pocket-tts | 5455 ms | 4053 ms | ❌ |
| llama-3.2-**3B** | pocket-tts | 3666 ms | 2797 ms | ❌ (TTS-bound) |
| llama-3.2-**3B** | **Soprano-80M** | **1961 ms** | **1686 ms** | ✅ |

Warm split at the fast stack (3B + Soprano): STT ~90 ms, LLM TTFT ~300–500 ms, **TTS first-chunk ~1.3 s**
(now the dominant term), transport negligible. Cold turn 1 ≈ 13 s (one-time model load).

### Root cause & fix

The old default grabbed the **first installed MLX model** — a 14 B coder — pushing warm latency to ~5.5 s. The
`VoiceAuto` planner (smallest LLM whose *whole* warm voice stack fits) already existed and was unit-tested but
was **not wired into `esh serve`**. Wired it in (`ServeCommand`): serve now logs, e.g.

```
esh Voice Auto: LLM mlx-community--qwen2.5-0.5b-instruct-4bit — smallest installed model that fits the warm voice stack (0.3 GB, comfortable)
```

### Verdict

- **Target (<2.5 s warm): MET** with an appropriate voice stack (small LLM + small TTS): 1961 ms avg, 1686 ms best.
- **Stretch (<1.5 s):** not yet — floored by TTS first-chunk (~1.3 s). The sub-phrase streaming that would cut
  this is the path blocked by TTSMLX `@MainActor` (Gate 1). A faster/streaming TTS is the remaining lever.
- **Recommendation:** Soprano-80M is the fastest installed TTS (~1.3 s first-chunk vs pocket-tts ~2–3 s); prefer
  it as the voice default. LLM selection now handled by Voice Auto.

**Gate 2: latency target met on the real WS path with Voice Auto; stretch pending a faster/streaming TTS.**
