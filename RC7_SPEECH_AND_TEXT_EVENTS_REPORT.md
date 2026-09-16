# esh v2.4.0-rc.7 — Portable Speech (§4) + Text-Path Events (§5)

Phase 2 of the Esh Studio capability work, additive to rc.6. Built on the rc.6 branch
(`g1-multimodal-facade`), so it inherits the rc.3 split, rc.4 coexistence, rc.5 Apple-FM streaming, and the
rc.6 multimodal facade.

## §4 — Portable on-device speech (iOS + macOS, Apple frameworks, no model download)

New public providers in `EshCore`, wired into `EshRuntime.makeDefault`:
- **`audio.synthesizeSpeech`** — `AppleSpeechSynthesizeProvider` (AVSpeechSynthesizer) renders text to a
  **WAV `Artifact`**; honors `voice` / `language` / `speed` from `ExecutionOptions`.
- **`audio.transcribe`** — `AppleSpeechTranscribeProvider` (SFSpeechRecognizer, **on-device**) streams
  `.textDelta`; requests authorization and fails honestly if denied/unavailable (never silent).
- `capabilityAvailability()` reports STT by the recognizer's authorization status
  (`ready` when authorized/not-yet-asked, `unsupportedOnDevice` when denied/restricted).

## §5 — Tool-calling, reasoning, structured output on the text path (additive, honest)

- `EshGenerationRequest` gains `responseFormat`, `tools`, `toolChoice`; `EshGenerationEvent` gains
  `.reasoningDelta` and `.toolCall`; `EshGenerationResult` gains `reasoning` and `capabilityResolution`.
- **Structured output** — resolved in the facade path via `CapabilityResolver`: native constrained decoding
  when the backend supports it, otherwise an injected instruction; a strict + unsupported request fails with
  a typed error rather than silently degrading.
- **Reasoning** — separated from the visible answer: live `.reasoningDelta` for the explicit
  `<think>…</think>` format (streaming splitter with correct handling of tags split across chunks), and an
  authoritative split (explicit **and** implicit-open) on the final result via `ThinkingParser`. Plain
  generation is byte-for-byte unchanged when thinking is off.
- **Tools** — accepted and honestly reported via `capabilityResolution`: native local tool-calling is not
  available on esh's on-device runtimes, so `tools` resolve as *rejected* and **no `.toolCall` is ever
  fabricated**; the `.toolCall` event exists for when a backend natively produces one.

## Verification

- **Tests (all green):** reasoning separation (streaming, one-shot, implicit-open), structured-output
  resolution, honest tool rejection, streaming splitter unit tests (incl. tags split across chunk
  boundaries), TTS produces a real non-empty WAV artifact, speech discovery. Full portable suite:
  **485 tests / 76 suites** pass.
- **iOS:** `xcodebuild -scheme EshRuntime` for iOS Simulator — BUILD SUCCEEDED (facade + speech + Vision on iOS).
- **Published remote tag:** a fresh external consumer pinning `exact: "2.4.0-rc.7"` resolves, builds, and
  runs — `tts: ready · stt: ready`, the §5 request API compiles, and it synthesized a **67 KB WAV** audio
  artifact through the remote-pinned SDK.

## Published

- Tag **`v2.4.0-rc.7`** → commit `19d52d5` (branch `g1-multimodal-facade`).
- Release: <https://github.com/fil-technology/esh/releases/tag/v2.4.0-rc.7> (prerelease).
- llama.xcframework unchanged; `EshLlamaCpp` reuses the immutable `v2.4.0-rc.4` asset. rc.1–rc.6 immutable.

## Migration note for consumers

Adding `.reasoningDelta` / `.toolCall` to `EshGenerationEvent` means any consumer with an **exhaustive
`switch`** over it must add those cases (or a `default`). Everything else is purely additive.

## Still staged (§3)

macOS-only **image / vision / audio(SFX) / music / video-understanding**. These providers shell out to a
**Python (MLX) bridge**, so exposing them to a consumer app needs a new macOS-only capabilities product
(MLX/TTSMLX, not swift-syntax) **and** a decision on distributing a Python runtime to consumer apps. iOS
cannot run them (Python/MLX); discovery reports them `unsupportedOnPlatform` there and `comingLater` on
macOS. Video **generation** does not exist in esh.
