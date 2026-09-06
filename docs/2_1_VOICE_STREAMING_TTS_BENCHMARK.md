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
