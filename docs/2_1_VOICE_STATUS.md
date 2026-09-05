# esh 2.1 — Voice 2.1 / Conversational Voice Runtime (status)

**Status (2026-09-05):** foundation increment. A canonical, server-owned **VoiceSession runtime core** is built
and unit-tested. Live audio I/O, streaming STT/TTS, a duplex transport, echo handling, and the live frozen
benchmark are **not** done. **Verdict: VOICE 2.1 NOT READY** (honest — see gates below).

## esh / Ashex boundary (spec §1)
esh owns: mic streaming, VAD/endpointing, STT, partial transcripts, inference execution, TTS, playback/chunks,
barge-in, cancellation, latency, **bounded** voice-session context, runtime/model selection, Model Fit,
lifecycle, typed events, local Web reference UX. Ashex owns: autonomous goals, durable personal semantic
memory, tools/actions, Mac/browser automation, permissions, long-running workflows. The runtime core here
keeps only bounded working-memory context and never persists it — that boundary is enforced in the type.

## Repository truth (audit before building)
- A **full conversational loop already exists, but entirely client-side** in `Sources/EshCore/Web/WebChatPage.swift`
  (mic → Web-Audio RMS VAD → `/v1/audio/transcriptions` → chat SSE → sentence-chunked `/v1/audio/speech`, with
  a turn-id barge-in guard). There was **no server-owned runtime, no typed voice state/events, no `voice.*` capability**.
- **STT**: warm actor `SpeechRuntimeManager` + bridge `speech-serve` (mlx_audio Parakeet) — model resident, but
  **whole-file request/response, not streaming**.
- **TTS**: `TTSMLX` (external, vendored). esh uses only the **buffered** `synthesize` (whole-utterance WAV);
  the package's `synthesizeStream` (chunked PCM) is **unused**, and TTS weights are **loaded per call** (latency risk).
- **No server-side VAD**; **no WebSocket/duplex transport** (HTTP + SSE only); `CapabilityEvent` has **no audio-delta** case.
- Existing hooks to reuse: `RuntimeLifecycleManager.setExternalReservation` + `ModelFitService.ttsReserveGB`
  (co-residency under one memory budget), and `ExecutionPlan.consumesOutputOf` (STT→LLM→TTS pipeline shape).

## What is built now (this increment) — `Sources/EshCore/Voice/`
A transport- and hardware-agnostic runtime core, unit-tested with fakes (no hardware):
- **`VoiceSession.swift`** — typed state machine `idle → listening → speechDetected → transcribing → thinking →
  speaking → interrupted → error → ended`; **bounded** `VoiceConversationContext` (turn + character caps, reset);
  `VoiceEndpointPolicy` / `VoiceInterruptionPolicy`; `VoiceSessionConfig` (language + model pins, nil = Auto);
  `VoiceTurnMetrics` (the §14 latency budget: speech-end → final STT → first token → first audio → first audible;
  barge-in → playback stopped).
- **`VoiceEvent.swift`** — the normalized typed event vocabulary (spec §4): `session.started`, `input.level`,
  `vad.speech_started/ended`, `transcript.partial/final`, `assistant.thinking_started/text_delta/text_final`,
  `tts.started/audio_chunk/finished`, `interruption.detected`, `playback.cancelled`, `session.error/ended`.
- **`VoiceProviders.swift`** — narrow async seams `VoiceTranscriber` / `VoiceResponder` / `VoiceSpeaker` (so the
  core is testable and wires to the real backends via thin adapters later), plus a deterministic
  `VoicePhraseChunker` (audible output begins on the first phrase, not the whole reply).
- **`VoiceSessionOrchestrator.swift`** — an `actor` that drives the state machine, runs a turn (STT → streamed
  inference → phrase-chunked TTS), enforces the bounded context, records metrics, and implements **barge-in**:
  genuine user speech during thinking/speaking cancels the in-flight turn, emits `interruption.detected` +
  `playback.cancelled`, drops the uncommitted reply, and returns to listening — **no stale audio, no orphan turn**.

### Tests (`Tests/EshCoreTests/VoiceSessionTests.swift`, 8 tests, green)
Ordered normal-turn events + context update + metrics; **barge-in** cancels playback, resumes listening, and does
not commit the interrupted reply; bounded-context turn/char caps + reset; phrase chunking + flush; empty
transcript → no reply; transcriber error → recoverable `session.error`, session survives; `end()` terminal + idempotent + stream closes.

## What is NOT done (honest gaps → why NOT READY)
- **No real adapters wired end-to-end.** The core runs on fakes; adapters for STT (`SpeechRuntimeManager`),
  inference (language provider), and TTS (`TTSMLX.synthesizeStream`) are designed but not implemented/verified.
- **Streaming STT: absent** (backend is whole-file). Real partial transcripts need a streaming-capable model + protocol.
- **Streaming TTS: not wired** (TTSMLX supports it; esh does not call it yet). TTS still load-per-call.
- **Server-side VAD/endpointing: none** (only browser RMS today).
- **No duplex transport** (WebSocket/WebRTC) and no `CapabilityEvent` audio-delta path; the core's event stream
  is not yet exposed over the wire.
- **Barge-in/echo not acoustically tested** (needs real mic/speaker; headphones-first baseline planned).
- **No live frozen benchmark** (see plan); **multilingual (en/ru/he) untested live**; **voice Install-and-Resume**
  and **offline/packaging** not verified.
- **Web reference UX** still uses the client-orchestrated loop, not the server runtime.

## Frozen benchmark plan (spec §20 — defined, not yet run live)
Fixtures: short Q/A; 20–30 s utterance; long reply; barge-in after ~1–2 s; rapid second interruption; silence;
background noise; en/ru/he where supported; 10–20-turn endurance. Metrics: speech-start/end latency, final STT,
first LLM token, first TTS audio, speech-end→audible, barge-in→playback-stopped, STT/TTS observations,
peak/resident memory, provider/model stack, errors/recovery. **Requires live audio I/O — not runnable headlessly.**

## Lifecycle / memory (spec §13)
Plan: attach a warm Voice runtime to `RuntimeLifecycleManager` via the external-reservation hook so STT+LLM+TTS
co-reside under one 32 GB budget with eviction under pressure; keep TTS resident (fix load-per-call). Not yet built.

## Verdict
```
VOICE 2.1 NOT READY
```
A strong, tested, server-owned runtime core exists (state machine, typed events, bounded context, barge-in +
cancellation semantics, latency-metric model). It is **not** a working end-to-end live voice runtime yet:
real adapters, streaming STT/TTS, server-side VAD, a duplex transport, acoustic barge-in/echo testing, the live
benchmark, multilingual verification, voice Install-and-Resume, and offline/packaging remain.

## Recommended next milestone (do not auto-start)
**Voice 2.1 — Live Path & Duplex Transport:** wire the three real adapters into the runtime core; add a
WebSocket duplex transport that carries the typed `VoiceEvent` stream + mic chunks; wire `TTSMLX.synthesizeStream`
and keep TTS resident; add a server-side VAD/endpointer; then run the frozen benchmark live (headphones-first)
and re-evaluate the gate. Do not begin without approval.
