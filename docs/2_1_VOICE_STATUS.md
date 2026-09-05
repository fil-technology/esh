# esh 2.1 — Voice 2.1 / Conversational Voice Runtime (status)

**Status (2026-09-05, live-path pass):** the canonical server-owned **VoiceSession runtime core** is now wired
to the **real local backends** and a real server-owned conversational turn (STT→LLM→TTS) is **proven headlessly**
(WAV-driven, no live mic). A server-side acoustic VAD/endpointer is built and unit-tested. Live-mic realtime
duplex transport, acoustic barge-in/echo, warm co-residency, and the live frozen benchmark remain.
**Verdict: VOICE 2.1 EXPERIMENTAL** (the live path works; material realtime/UX limitations remain — see gates).

## Realtime duplex transport (this pass) — server-owned voice over WebSocket, verified headlessly
A real WebSocket duplex transport now carries the whole loop server-side, verified end-to-end over a loopback
socket with a headless simulator (no browser/mic needed):
- **RFC 6455 WebSocket layer** (`WebSocketFrame.swift`) — handshake accept-key + masked/unmasked frame
  encode/decode, oversize/bad-opcode guards. **6 codec tests.**
- **Wire protocol** (`VoiceWireProtocol.swift`) — TEXT frames = JSON control (client→server) + JSON VoiceEvents
  (server→client); BINARY frames = raw PCM16 mic in + `VoiceAudioFrame` (turn/seq/sampleRate/isFinal header)
  TTS out. No base64 of realtime audio; canonical `VoiceEvent` stays separate from the wire.
- **Server** (`VoiceWebSocketServer.swift`) — one VoiceSession per connection; ingests mic PCM → **server
  EnergyVAD finds utterance boundaries** → orchestrator (STT→LLM→TTS + barge-in); streams events + binary TTS
  back. FIFO-serialized orchestrator commands (submit can't overtake a barge-in); session/turn ids; disconnect
  reaps the session. Wired into `esh serve` on a companion port (`ws://host:port+1/v1/voice/stream`, verified listening).
- **Client + headless simulator** (`VoiceWebSocketClient.swift`) — streams PCM in realtime-sized chunks,
  receives events/audio, can barge in and disconnect; drives the SAME endpoint the browser will.
- **Transport tests (3, green):** full turn over WS (handshake → mic PCM → VAD endpoint → STT→LLM→TTS →
  binary audio); **barge-in over WS** (mid-playback speech → `interruption.detected` + `playback.cancelled`);
  **disconnect mid-turn → server healthy, a new session still completes** (no zombie/orphan).

This covers the transport, codec, VAD-on-stream, simulator, transport barge-in, and disconnect gates. Remaining:
the browser thin client (JS; needs a real mic to verify), streaming TTS, Voice Auto, combined Fit, voice
Install-and-Resume, offline-over-transport, multilingual fixtures, doctor fields, packaging.

## Warm co-residency — the cold-latency blocker is SOLVED (measured, M1 Pro / 32 GB)
`esh voice-bench` runs N turns through ONE orchestrator with shared resident collaborators (warm STT worker,
persistent MLX LLM via `RuntimeLifecycleManager` with `ESH_MLX_PERSISTENT=1`, reused TTS). Measured:

| turn | STT | LLM first token | TTS first audio | endpoint→audible | free MB |
|---|---|---|---|---|---|
| 1 (cold) | 7443 ms | 6921 ms | 1176 ms | 15540 ms | 18980 |
| 2 (warm) | 68 ms | 551 ms | 880 ms | **1499 ms** | 18874 |
| 3 (warm) | 69 ms | 747 ms | 950 ms | **1765 ms** | 18719 |

**Warm endpoint→audible ≈ 1.6 s** (avg 1632 ms) — under the <2.5 s target, approaching the <1.5 s stretch.
Warm STT ~68 ms, warm LLM first token ~550–750 ms, warm TTS first audio ~900 ms. Memory stayed flat (~18.7 GB
free with all three models co-resident — no leak, no unmanaged workers). **Conclusion: the local stack reaches
realtime-grade latency when warm; the ~38 s cold figure was purely model-load, not a per-turn cost.** TTS first
audio (~900 ms, buffered) is the largest warm component and is the best target for streaming TTS next.

## Live path (this pass) — real backends, proven server-owned turn
- **Real adapters** (`Sources/esh/Voice/VoiceAdapters.swift`): `SpeechRuntimeTranscriber` → warm
  `SpeechRuntimeManager` (parakeet, whole-file); `LanguageResponder` → `ExternalInferenceService.inferStream`
  (real streamed deltas, Scheduler-selectable model, honors pins); `BufferedTTSSpeaker` → `AudioSpeechGenerator`
  (TTSMLX; buffered per phrase → audible on first phrase).
- **Server-side VAD** (`Sources/EshCore/Voice/EnergyVAD.swift`): acoustic RMS + start/end hysteresis + max-utterance
  cap; runs during playback (for barge-in); unit-tested. Research note: Silero/sherpa-onnx VAD is the evidence-driven
  upgrade; the endpointer is a seam so a learned model drops in.
- **Real turn proof** (`esh voice-turn --in <wav>`): drove a recorded utterance through the orchestrator with real
  STT+LLM+TTS. Result: STT transcribed "What is the capital of France?" → llama-3.2-3B replied (streamed) →
  pocket-TTS produced assistant audio. Cold latencies (per-stage cold loads, no warm pool): **finalSTT ≈ 7.5 s**,
  **speech-end→audible ≈ 38 s**. These are cold-load-dominated, NOT production realtime latency.
- **Transport decision:** **WebSocket** is chosen for the duplex realtime transport (continuous mic chunks up,
  typed `VoiceEvent` down as JSON control frames + binary audio frames). WebRTC is not justified for a local
  loopback runtime. The WebSocket transport + browser-client migration are the primary remaining build and are
  **not implemented** this pass (cannot be verified headlessly without a browser mic).

### Honest live-path limitations
- Latency is **cold** (no warm co-residency; TTS still load-per-call). Warm residency via `RuntimeLifecycleManager`
  is the key latency fix and is not yet wired.
- Multi-phrase reply audio is currently concatenated per-phrase WAVs (only the first is a valid standalone WAV);
  streaming PCM (`TTSMLX.synthesizeStream`) or PCM merge is needed for a single clean reply stream.
- The proof is **WAV-driven**, not a live microphone; realtime duplex, acoustic barge-in, and echo are unproven.

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
VOICE 2.1 EXPERIMENTAL
```
The server-owned runtime is wired to the real local stack; a real conversational turn (STT→LLM→TTS) is proven
headlessly; warm co-residency hits realtime latency (~1.6 s endpoint→audible); and a **WebSocket duplex
transport now carries the full loop server-side, verified end-to-end (turn + barge-in + disconnect) over a
loopback socket with a headless simulator**, and is wired into `esh serve`. It stays **experimental** because
the parts that genuinely need a browser mic/speaker + human ears are not done: the browser thin client, real-mic
barge-in, echo/speakerphone acceptance, streaming TTS, Voice Auto, combined Voice Fit, voice Install-and-Resume,
offline-over-transport, multilingual-by-ear, doctor fields, and packaging. These keep **PR #8 DRAFT**.

## Recommended next milestone (do not auto-start)
**Voice 2.1 — Live Path & Duplex Transport:** wire the three real adapters into the runtime core; add a
WebSocket duplex transport that carries the typed `VoiceEvent` stream + mic chunks; wire `TTSMLX.synthesizeStream`
and keep TTS resident; add a server-side VAD/endpointer; then run the frozen benchmark live (headphones-first)
and re-evaluate the gate. Do not begin without approval.
