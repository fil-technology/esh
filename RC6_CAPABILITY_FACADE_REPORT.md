# esh v2.4.0-rc.6 — Multimodal Capability Facade (Phase 1)

Answers the Esh Studio capability-gap request. The audit was **accurate**: the portable SDK (`EshCore`,
`EshRuntime`, `EshLlamaCpp`) exposed only text + model-management; the UCMR multimodal contract and its
providers existed and were `public` in `EshCore` but nothing wired them into the public facade. rc.6 wires
them — additively, without breaking the rc.5 text API. Built on rc.5 (`ee613b0`), so it also inherits the
rc.3 dependency split and rc.4 llama.cpp coexistence.

## What shipped (§1, §2, §6)

**§1 — public facade on `EshRuntime`:**
- `func execute(_ ExecutionRequest) async throws -> ExecutionResult`
- `nonisolated func stream(_ ExecutionRequest) -> AsyncThrowingStream<CapabilityEvent, Error>` (cooperative
  cancellation, same contract as the text `stream`)
- `static func makeDefault(...) async -> EshRuntime` — assembles platform text backend(s) + the portable
  capability providers so a consumer never hand-builds a `CapabilityRegistry`
- `static func makeWithEmbeddedGGUF(...) async -> EshRuntime` (EshLlamaCpp) — same, plus on-device GGUF text
- A bare `EshRuntime()` stays text-only; `execute` throws a typed `CapabilityError.unsupported` until wired.

**§2 — portable providers wired (iOS + macOS), text routed back through the runtime (no second stack):**
`image.ocr` (Apple Vision, zero-dep), `vector.generate` (SVG), `webArtifact.generate` (Website/HTML),
`project.generate` (Code project), `language.*` (text).

**§6 — honest discovery:** `func capabilityAvailability() -> CapabilityAvailabilitySnapshot` with per-
capability states `ready · requiresDownload · installing · temporarilyUnavailable · unsupportedOnDevice ·
unsupportedOnPlatform · comingLater`. Registry-driven: capabilities flip to `ready` automatically as more
providers are wired.

## Verification

- **Unit tests (5, all green):** `execute`/`stream` produce a `.webProject` artifact via a mock text
  backend; availability reports honest states (OCR/web/svg/project/language ready; image/music not ready);
  a wired-but-not-ready backend reports non-ready text states; a bare runtime throws.
- **Full portable regression:** 475 tests / 75 suites pass.
- **iOS:** `xcodebuild -scheme EshRuntime` for iOS Simulator — BUILD SUCCEEDED (facade + Vision OCR compile
  on iOS).
- **Published remote tag:** a fresh external consumer pinning `exact: "2.4.0-rc.6"` resolves, downloads the
  (reused, immutable rc.4) llama binaryTarget, builds, and runs `makeDefault()` + `capabilityAvailability()`
  → `OCR: ready · web: ready · imageGen: comingLater`; `execute`/`stream` reachable.

## Published

- Tag **`v2.4.0-rc.6`** → commit `e9b5d1e` (branch `g1-multimodal-facade`, from rc.5 `ee613b0`).
- Release: <https://github.com/fil-technology/esh/releases/tag/v2.4.0-rc.6> (prerelease).
- llama.xcframework **unchanged** since rc.4; `EshLlamaCpp`'s `binaryTarget` reuses the immutable
  `v2.4.0-rc.4` asset (`esh-llama-xcframework-4a8993735419.zip`, checksum
  `4366e678d655672b6f9e990c1b2a6a23df6982cd063beabced97126d4454717e`). rc.1–rc.5 immutable.

## What the app can do now (Phase 1)

Pin rc.6 → `EshRuntime.makeDefault()` (or `makeWithEmbeddedGGUF`) → drive **Create** (SVG / Website / Code
artifacts) and **OCR** through `execute`/`stream`, with `capabilityAvailability()` driving honest per-mode
availability. No hand-built registry, no reaching into internals.

## Staged for rc.7+ (honest, not hidden)

Each reports `unsupportedOnPlatform`/`comingLater` via discovery until wired:

- **§3 — macOS image / vision / audio / music / video-understanding.** These providers live in
  `EshMacRuntime` and shell out to a **Python (MLX) bridge**. Exposing them to a consumer app needs a new
  **macOS-only capabilities product** (depending on MLX/TTSMLX but not swift-syntax, to preserve rc.3/rc.4)
  **and** a solution for distributing the Python runtime to a consumer app — a genuine design task, not a
  wiring change. iOS cannot run these (Python/MLX), so they stay `unsupportedOnPlatform` there.
- **§4 — portable Apple `Speech` (STT) + `AVSpeechSynthesizer` (TTS)** for `audio.transcribe` /
  `audio.synthesizeSpeech`. Portable and feasible; needs audio I/O + usage-string/permission handling.
- **§5 — tool-calling + reasoning + structured-output events on the text path.** The request/facade types
  exist, but emitting `.toolCall`/`.reasoningDelta` honestly requires the `InferenceBackend`/`BackendRuntime`
  contract to surface structured events (today `generate` yields plain text) — a deeper, backend-touching
  change.

## Not in esh at all
Video **generation** does not exist in esh; discovery makes no claim for it.
