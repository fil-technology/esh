# Changelog

All notable changes to Esh should be documented in this file.

The format is based on Keep a Changelog, and Esh follows Semantic Versioning.

## 2.1 Capability Status (authoritative — supersedes earlier per-entry labels below)

The dated status/closure docs are the current source of truth; historical entries in this file keep the label
they had **when written** and are not rewritten. As of the Voice 2.1 merge (`63552f4`, 2026-09-06), the
authoritative status is in `docs/2_1_RELEASE_QUALIFICATION_MATRIX.md`. Notable updates vs. earlier entries:

- **image.edit → PRODUCTION** (default FLUX.2 Klein 4B, Apache-2.0; FLUX `kontext` stays Experimental,
  non-commercial). Earlier entry below labels it EXPERIMENTAL — that was its state at the time.
- **Voice 2.1 → PRODUCTION** for English (headphones), realtime `/voice`. RU/HE are non-production. Earlier
  `docs/2_1_VOICE_STATUS.md` labeled Voice EXPERIMENTAL (cold-load latency) — superseded by
  `docs/2_1_VOICE_CLOSURE_STATUS.md`.
- **Non-commercial models (CC-BY-NC-4.0), opt-in and labeled:** `music.generate` (Experimental), neural
  `audio.generate` (SFX), and the `image.edit` `kontext` backend. Do not use these in a commercial context.
- Experimental (labeled): `music.generate`, `image.segment`, `audio.diarize`, FLUX `kontext` edit.
- Unsupported / out of scope for 2.1: Tier C (Node) managed runtime, video generation, audio
  editing/stems/remix, `audio.understand`.

esh 2.1's **feature freeze** (`docs/2_1_FEATURE_FREEZE.md`) concluded with the **`v2.1.0`** release
(2026-09-07). esh 2.1 is **complete and shipped** — see `[2.1.0]` below.

## [Unreleased]

### SDK — v2.4.0-rc.32 (image.edit style presets: first-class "3D animation" via FLUX.2 Klein 4B + LoRA)

Surfaces esh-web's Imagine "3D animation" stylizer as a first-class, discoverable SDK feature. The stylizer is
**FLUX.2 Klein 4B** (Black Forest Labs, Apache-2.0) as an edit backend + the **`Latentiq/Flux2_Klein_4B_3D2AI`
LoRA** — a 4B model that fits 32 GB (measured ~11 GB peak, ~1.8 min, no swap thrash), identity-preserving and
commercial-safe. (This corrects an earlier assumption that the Pixar path was the 20B Qwen-Image-Edit-2511,
which does NOT fit 32 GB.)

- **Named style presets** (`MacImageStyle` / `MacImageStyles`, new `ImageStylePresets.swift`): a style is a
  curated backend + optional LoRA + prompt. Built-in **`3d-animation`** → flux2-klein + the 3D2AI LoRA. A
  consumer applies it by name via the `image.edit` option `style: "3d-animation"` — no hard-coded model paths.
- **image.edit now forwards the real edit knobs.** The `advancedImageEdit` bridge request maps `style`
  (resolved to backend + LoRA + composed prompt) plus direct passthroughs `backend`, `lora`, `loraScale`,
  `quantize`, `guidance`, `steps`, `seed`, `maxEditSide` — previously it only forwarded image + instruction, so
  a consumer could not select a backend or a LoRA at all.
- **LoRA resolution** (`resolveLoRAPath`): prefers the cached local adapter in the image HF cache, else falls
  back to the HF repo id so mflux downloads it on first use (offline-first, no hard-coded snapshot paths).
- **Discovery**: `MacCapabilities.imageStyles()` lists the presets (id, display name, backend, license,
  commercial flag) so a consumer (Esh Studio, the CLI) enumerates styles instead of hardcoding them.
- Runs on the managed-Python image engine — available to consumers that can run the managed runtime (the CLI /
  `esh web`, non-sandboxed hosts). A sandboxed host that cannot spawn Python needs the native route (the native
  FLUX.2 Klein port, tracked next). Validated live: couple photo → 3D animation on a 32 GB M1 Pro via both the
  rc.32 bridge and esh 2.2.0's own bridge under the mflux-ready venv. Tests: catalog/discovery, prompt
  composition, style→backend/LoRA/prompt resolution, direct-override passthrough. Full regression + iOS green.

### SDK — v2.4.0-rc.31 (Qwen-Image-2.1: first-class non-commercial image.generate + image.restyle provider)

Adds `Qwen/Qwen-Image-2.1` (Sep 2026) as a first-class esh image provider through the existing managed-Python/
MFLUX compatibility runtime — no new runtime architecture. Runtime = MFLUX's MLX port (`mflux>=0.20.0`,
`mflux-generate-qwen-2.1`), a single-stream block-causal 7.1B DiT + 64-ch causal VAE + Qwen3-VL text encoder.

- **New compat engine `qwen-image-2.1`** with capabilities **`image.generate` (txt2img)** and **`image.restyle`
  (img2img via `--image-strength`)**. It deliberately does NOT claim `image.edit`: MFLUX's port has no
  edit/instruction variant (needs the Qwen3-VL vision tower), no multi-reference, no LoRA, and its VAE decode
  returns RGB only (no transparent/RGBA output). Only options the port actually consumes are forwarded
  (prompt, steps[40], seed, width, height, guidance/negative-prompt true-CFG, quantize, image-path/strength,
  low-ram) — no ignored knobs.
- **Commercial-use gate (new, general).** `CompatibilityEngineManifest` gains `licenseIdentifier` +
  `commercialUse`; `CapabilityProviderDescriptor` gains `commercialUse`; `CapabilityRegistry.candidates(...)`
  now excludes non-commercial providers from Auto selection entirely — they are reachable ONLY via an explicit
  model pin. So Qwen-Image-2.1 (Qwen Research License, NON-COMMERCIAL) can never silently become a
  commercial-production default; eval/dogfood use stays available by pinning `"qwen-image-2.1"`. Existing
  providers default to `commercialUse=true` (unchanged).
- **Resource-aware fit gating.** The manifest declares a `CapabilityResourceProfile` (~30 GB peak, 24 GB
  system-volume headroom, ~33 GB download) surfaced on the descriptor — honest because the Qwen3-VL text
  encoder (~17.5 GB) stays bf16-resident even when the transformer/VAE are quantized (~46 GB bf16 peak). So
  fit-gating correctly refuses it on <64 GB machines / near-full disks unless explicitly pinned.
- Storage/provenance: reuses the esh HF image cache on the assets volume; artifact provenance now records
  `modelID`. Truthful non-commercial license is surfaced in the manifest, descriptor, and bridge output.
- **Validated live on M1 Pro 32 GB** (the exact target): `image.generate`, q4 + `--low-ram`, 1024², 40 steps
  → excellent photoreal quality, **fit 32 GB with no swap thrash** (~18–19 GB real peak, swap flat at ~1.6 GB
  baseline), ~21 min cold (incl. 33 GB weight load). bf16 (~46 GB peak) does not fit 32 GB and is correctly
  gated. Tests: manifest/descriptor wiring, the pin-only commercial gate, bridge command + generate/restyle
  request translation. Full regression + macOS + iOS builds green.

### SDK — v2.4.0-rc.30 (audio engines: isolated per-engine venvs — voice-clone + AudioGen fixed, all four validated)

Fixes the Esh Studio handoff where compatibility audio engines reported false/blocking dependency states and
voice-clone could not run. Root cause: `inspect`/`install`/`repair` always probed the **main** managed venv,
but two engines actually run their heavy runtime in a **separate** venv (their dependency pins can't share the
MLX runtime). So AudioGen's `mlx_audiocraft` (isolated) was probed against the main venv → a spurious
"missing module 'mlx_audiocraft'", and voice-clone's coqui-tts (`torch<2.9` / `transformers<5`) was
unbuildable in a shared venv at all.

- **Isolated runtimes are now first-class.** `CompatibilityEngineManifest.isolatedRuntime` (`IsolatedRuntime`:
  `dirName` + `envVar` + `modules`) declares a dedicated venv. The host provisions it from the esh-owned base
  interpreter, installs/probes its modules **there** (never the main venv), and points the bridge at it via the
  env var at run time. `soundFX` → `audiogen-venv` / `ESH_AUDIOGEN_PYTHON`; `voiceClone` → `voiceclone-venv` /
  `ESH_VOICECLONE_PYTHON`. The manifest's top-level `requiredModules` stay the shared bridge deps.
- **One interpreter per engine, end to end.** `inspect`/`install`/`repair` now resolve the correct venv per
  engine, so an isolated engine's real state is reported (no more false "missing module" against the main
  venv), and install provisions the isolated venv + its deps. This also removes the stale/misleading status the
  consumer saw, because the probed interpreter finally matches the one the engine runs in.
- **voice-clone now runs in its own venv.** The shared bridge (main venv) launches an isolated
  `esh_voiceclone.py` worker (mirroring AudioGen's `esh_audiogen.py`) located via `ESH_VOICECLONE_PYTHON`, so
  `coqui-tts`'s `torch<2.9` / `transformers<5` never destabilize the MLX LLM/VLM runtime (main venv stays on
  torch 2.14 / transformers 5.17).
- **Isolated venvs live on the internal APFS state root** (`~/.esh/runtime/isolated/<name>`), alongside the
  main venv — NOT the external assets volume, where exFAT AppleDouble `._*` sidecars poison pip's metadata scan
  and break `python -m venv` + pip (`UnicodeDecodeError`). Only model weights/caches stay on the assets volume.
- **Validated live, real generation (all on-device):** music (MusicGen 4.9 s WAV), sound (AudioGen "rain on a
  tin roof" 4 s, isolated venv), diarize (2-speaker clip correctly split at 4.5 s), and voice-clone (XTTS-v2
  6.4 s cloned from a reference sample, isolated venv on torch 2.8 / transformers 4.57). Non-commercial models
  (MusicGen/AudioGen/XTTS, CC-BY-NC / CPML) remain opt-in, labeled, dogfood-only.
- Tests: `isolatedRuntimesWiredForVoiceCloneAndSoundFX`, `bridgeEnvironmentHonorsIsolatedInterpreterOverride`,
  and updated `voiceCloneManifestIsDeclared` (coqui-tts now in the isolated runtime, not `requiredModules`).

### SDK — v2.4.0-rc.29 (PhotoMaker: honest resource profile + opt-in speed knob + prewarm)

Measurement-driven. A live MLX peak sweep of the PhotoMaker v1 identity tier showed the peak is
**weights-bound and resolution-independent**: 12.38 GB at 1024 and 12.36 GB at 768 (resident fp16 SDXL
`active ≈ 7.85 GB` + a ~4.5 GB fixed working set; the VAE decode is already tiled at 512 px). So lowering the
edit resolution does **not** reduce peak — only quantizing the fp16 weights would (tracked as a follow-up
spike).

- `EshPhotoMaker.resourceProfile.estimatedPeakMemoryGB` corrected **14 → 13** (measured ~12.4 GB + margin),
  system-volume headroom **18 → 16**, so resource-aware Auto routing stops being over-conservative on
  16–32 GB Macs. (The old 14 was a padded estimate; the true peak is ~12.4 GB.)
- `editSize` is now a configurable, opt-in **speed/quality** knob (not a memory lever) — default stays SDXL
  native **1024** (max quality); a host can pass `makeWithImageEditTiers(photoMakerEditSize: 768)` for ~2×
  faster first generation (~40 s vs ~83 s denoise) at slightly lower fidelity. Clamped to a multiple of 8 in
  [512, 1024] via `EshPhotoMaker.clampedEditSize`.
- New public `EshPhotoMakerEngine.prewarm(onProgress:)` — pre-stage SDXL + PhotoMaker weights (token-free,
  checksum-pinned) so the first edit isn't blocked on a multi-GB download.
- Tests: deterministic `editSizeKnobAndHonestResourceProfile` (default 1024, clamp, `estimatedPeakMemoryGB
  == 13`). Peaks validated by a live on-device sweep.

### SDK — v2.4.0-rc.28 (new capability: audio.cloneVoice — zero-shot voice cloning, dogfood)

Adds the previously-missing voice-cloning capability as a macOS compatibility engine, mirroring the existing
MusicGen/AudioGen/diarization compat engines (managed Python + bridge script).

- **`CapabilityID.audioCloneVoice = "audio.cloneVoice"`** — synthesize text in the voice of a supplied
  reference-audio sample (distinct from `audio.synthesizeSpeech`'s fixed system voices).
- **Engine:** new `.voiceClone` compat engine (Coqui **XTTS-v2** via `coqui-tts`), inputs `[audio (reference)
  + text]` → WAV artifact; runs in the isolated audio venv with weights on the configured assets volume.
  **License: CPML (NON-COMMERCIAL) — dogfood-only**, exactly like MusicGen/AudioGen (not for commercial ship).
- Bridge `voice-clone` command + request mapping (text / referencePath / language / hfCache); honest failure
  when the engine isn't provisioned (no raw traceback).
- iOS reports `.unsupportedOnPlatform` (compat engines are macOS-only), same as the other audio engines.
- Tests: manifest declaration, provider execution (mock host), bridge request mapping + missing-reference
  rejection.

**Validated live end-to-end:** a real clone was produced through the actual bridge handler — reference WAV
(macOS `say`) → XTTS-v2 (~1.87 GB downloaded) → an 8.4 s, 24 kHz mono WAV; handler returned
`{provider: xtts-v2, license: cpml-noncommercial}`. The dogfood surfaced the dependency pins now encoded in
the manifest: `torchaudio` is required; `torch`/`torchaudio` `<2.9` (2.9+ needs `torchcodec`+FFmpeg);
`transformers` `>=4.57,<5` (coqui needs ≥4.57, 5.x drops `isin_mps_friendly`). **Known limitation:**
`transformers<5` can clash with the main runtime's transformers in a shared venv — the robust shape is an
isolated venv for this engine (like AudioGen), tracked as a follow-up. (Swift contract/provider/bridge
mapping remain unit-tested; the Python handler is exercised by the live run.)

### SDK — v2.4.0-rc.27 (fix: Hugging Face installs invisible to localModels() + reconcile data loss)

Bug fix. A Hugging Face model installed correctly (manifest + weight on disk) but never appeared in
`localModels()`, so it was unusable and uncounted — and `reconcileLocalModels()` would silently **delete** it.

Root cause: `LocalModelManager` assumed the curated layout everywhere. `statuses()` enumerated only
`LocalModelCatalog.models`, so a non-curated (HF / side-loaded) install was structurally invisible.
Install-verification (`isInstalled`, `reconcile`) checked a fixed `model.gguf` filename, but HF installs keep
the real filename (e.g. `Llama-3-8B-Web.Q8_0.gguf`) — so `reconcile` pass 1 treated the install as "broken"
and removed the manifest **and** the multi-GB file. Separately, HF GGUF installs recorded `spec.localPath` as
the install *directory* rather than the weight *file*, leaving them listed-but-unloadable.

- `statuses()` now merges the curated catalog with **installed manifests from the store**, surfacing
  non-curated installs (descriptor synthesized from the stored spec + HF provenance) as `.installed`.
- A single manifest-aware `installedWeightURL(id:)` ("is this install's real file present?") backs
  `isInstalled` and `reconcile`, honoring the manifest's actual filenames (legacy `model.gguf` still works).
  `reconcile` no longer deletes a valid non-curated install.
- HF **GGUF** installs now record `spec.localPath` at the weight file (MLX still uses the directory), and
  `reconcile` repairs older installs whose `localPath` pointed at the directory (`repairedModelPaths`) so they
  load without a re-download.
- Curated install behavior, the storage/fit gates, and pause/resume are unchanged.
- Tests: `LocalModelManagerTests` gains non-curated-install surfacing, the reconcile-doesn't-delete
  regression, and the stale-`localPath` repair.

Note for Esh Studio: the download ✓ was reported by the install session independently of `localModels()`; with
this fix a completed HF install now also appears in the inventory. (Studio's own "installed but not usable"
reconciliation remains a good belt-and-suspenders, but is no longer required for HF GGUF installs.)

### SDK — v2.4.0-rc.26 (fix: model downloads pegged ~200% CPU — per-byte stream read)

Performance fix. Multi-GB model downloads pinned ~2 cores for the whole transfer (fan/heat/battery,
competing with concurrent generation). Bytes on disk were always correct — purely a CPU-efficiency bug.

Root cause: `DownloadCoordinator` consumed the response via `for try await byte in stream.bytes`, and
`URLSession.AsyncBytes` yields the body **one `UInt8` per async iteration** (plus a one-byte `Data.append`).
An 8.5 GB file is billions of per-element async iterations — the per-byte loop, not the network/TLS, pinned
the cores.

- The read is now **block-based**: `NetworkRequestExecutor.dataStream(...)` drives a `URLSessionDataDelegate`
  that delivers whole `Data` blocks (16 KB–1 MB) and bridges them into an `AsyncThrowingStream<Data, Error>`.
  The write loop writes each block directly. Near-zero app CPU on large downloads.
- Everything else is preserved: connection-phase retry policy, per-file `Range` resume + 416 restart, the
  `Authorization` header for gated/private, the rich `DownloadState` progress (same ~64 KB emit cadence and
  byte-accounting), and pause/resume/cancel — consuming-task cancellation tears down the transfer (partial
  retained on disk) exactly as `AsyncBytes` did.
- Tests: `DownloadCoordinatorTests` gains multi-block reassembly (byte-exact across many blocks), resume via
  `Range` header, and 416 restart, all through a chunk-delivering `URLProtocol`.

### SDK — v2.4.0-rc.25 (fix: model installs blocked on exFAT / non-APFS storage)

Bug fix. On a non-APFS model-storage volume (e.g. an exFAT external SSD), `DeviceProfile.availableStorageBytes`
came back **0** even with hundreds of GB free, so `installPlan.storageSufficient` was false and installs were
refused with `insufficientStorage(freeBytes: 0)`.

Root cause: `SystemDeviceProfileProvider.availableStorage(at:)` read **only**
`volumeAvailableCapacityForImportantUsage`, which is APFS-specific and returns 0 on exFAT/FAT, and accepted
that 0 as valid — a second, divergent reader from the canonical `SystemStorage.snapshot`.

- `DeviceProfileProvider.availableStorage(at:)` now delegates to the canonical `SystemStorage.snapshot` — one
  cross-filesystem reader. `SystemStorage` trusts important-usage only when positive and falls back to plain
  `volumeAvailableCapacity`; a genuinely full volume now reports `0` (not "unknown"), and capacity is `nil`
  only when neither signal is readable. A pure `SystemStorage.selectAvailableBytes(importantUsage:ordinaryAvailable:)`
  seam makes this testable without a real disk.
- `LocalModelManager`'s default storage probe is anchored to the **actual install destination**
  (`root.modelsURL`), so the gate measures the configured external volume, not the boot disk.
- Storage-capacity, system/swap headroom, and RAM/Model Fit remain separate gates — no resource gate weakened.
- Tests: `SystemStorageTests` (Cases A–D + unknown/clamp/real-probe) and an install-plan regression proving
  `storageSufficient == true` when important-usage is 0 but the volume has space. Real exFAT dogfood on a live
  volume: importantUsage 0 → esh reports 520 GiB, `installPlan.suitable == true`, and a real GGUF install
  landed on the exFAT SSD with no internal fallback.

### SDK — v2.4.0-rc.24 (Hugging Face OAuth + PKCE native sign-in)

Additive. Primary auth UX becomes "Continue with Hugging Face" (Authorization Code + PKCE, **public client,
no secret**); manual PAT stays as an Advanced fallback. esh owns the OAuth protocol; the consumer app owns
the browser + callback delivery. Verified against HF's live OIDC discovery + docs (public apps authenticate
with client_id only; PKCE `S256`; loopback any-port + custom-scheme redirects).

- **Single credential path:** new `HFCredential` (PAT + OAuth, with expiry/scopes/refresh metadata) stored as
  JSON in the Keychain; `loadToken()` stays the universal accessor, so every existing authenticated consumer
  (metadata/search/resolve, `DownloadCoordinator`, `HuggingFaceModelDownloader`, `HubApi`) uses OAuth with no
  forking. Legacy rc.23 raw-token Keychain values migrate to a PAT credential on read (no forced logout).
- **OAuth API (`EshRuntime`):** `beginHuggingFaceOAuth(configuration:)` → `HFAuthorizationRequest`;
  `completeHuggingFaceOAuth(callbackURL:requestID:)`; `cancelHuggingFaceOAuth(requestID:)`;
  `refreshHuggingFaceOAuthIfNeeded()`. `HFOAuthConfiguration` (endpoints default to HF), `HFOAuthClient`
  (public-client code exchange + refresh), `HFOAuthCallback`, `HFPendingOAuthSession` (transient, capped,
  600s TTL). esh never hardcodes a client ID — the consumer supplies it.
- **Scopes (least privilege):** `openid profile gated-repos read-repos`.
- **Redirect strategy:** esh is redirect-neutral (app delivers the callback); recommended
  `ASWebAuthenticationSession` + custom scheme `technology.fil.eshstudio://oauth/huggingface`; loopback
  (any port, RFC 8252) also accepted. Callback validated against the configured redirect URI.
- **Expiry/refresh:** `expires_in` → `expiresAt`; auto-refresh when a refresh token is issued; expired +
  non-refreshable → `.expired` account state / typed `oauthReauthenticationRequired` (never a bare 401).
- `HFAccountState` gains `.expired`; `HuggingFaceError` gains typed `oauth*` cases. Token redaction broadened
  to `hf_`/`hf_oauth_`/JWT/Bearer (not just the `hf_` prefix). Failed OAuth never destroys a working
  credential; success replaces atomically.
- Docs: `SDK_CAPABILITY_MATRIX.md` OAuth section + Esh Studio migration contract. Tests: deterministic OAuth
  matrix (`HFOAuthTests`, `HFOAuthFacadeTests`) — PKCE/state/URL/callback/exchange(no secret)/refresh/
  redaction/migration/atomic-replace/PAT-coexistence/OAuth-token threading. CI never needs live OAuth.
- NOTE: `HFAccountState` gains a case → consumers with an exhaustive `switch` must add `.expired` (or a
  `default`). Otherwise additive; no breaking changes to rc.23 behavior.

### SDK — v2.4.0-rc.23 (first-class Hugging Face model source, HF1–HF9)

Additive. A first-class Hugging Face source built on the existing model architecture — **no** second
downloader, catalog, or storage system.

- **Reference + resolve (HF1/HF2):** `HuggingFaceReference.parse` (owner/repo, huggingface.co URLs, `@rev`);
  `resolveHuggingFace` → `ModelSourceRecord` (metadata + access + license + compatibility + gated). Typed
  access states (`ModelAccessStatus`) and typed, UX-safe errors (`HuggingFaceError`).
- **Auth (HF3):** token + **Keychain** (`KeychainHFCredentialStore`); `connectHuggingFace`/`disconnect`/
  `huggingFaceAccountState` (`whoami`-validated). The public surface exposes account *state*, never the token.
  Token threaded into the download `Authorization` header, metadata/search/whoami, and `HubApi(hfToken:)`.
- **Candidates + fit + recommendation (HF4):** `huggingFaceArtifactCandidates` enumerates GGUF quants / the
  MLX layout, each with its own Model Fit (real per-file sizes via `?blobs=true` + `lfs.size`); exactly one
  `isRecommended` (heaviest that fits; lightest non-unsupported when fit is unknown).
- **Search (HF5):** `searchHuggingFace` (account's private/gated repos included when connected).
- **Install + provenance (HF6):** `installHuggingFaceArtifact` (one-shot) and `installHuggingFaceSession`
  (controllable — rich `DownloadState` events + pause/resume/cancel). Honors the configured external assets
  root (fails cleanly, never silent internal fallback). Records credential-free provenance on
  `ModelInstall.huggingFace` (repo, revision/commit SHA, files, format, quantization, license, gated/private).
- **Compatibility** is truthful — a raw HF resolve is at most `.compatible`, never `.verified`.
- Docs: `docs/SDK_CAPABILITY_MATRIX.md` → "Hugging Face model source". Fully mocked test matrix
  (`HuggingFaceModelSourceTests`, `HuggingFaceFacadeTests`, provenance in `HuggingFaceModelDownloaderTests`);
  CI never depends on live Hugging Face.
- NOTE: additive only. `ModelInstall` gains an optional `huggingFace` field (tolerant decode); no breaking
  changes. Studio migration: use the `EshRuntime` HF methods above; no direct HF internals.

### SDK — v2.4.0-rc.7 (speech + text-path events — Phase 2)

Additive to rc.6. Two more of the app's requested areas land through the public facade:

**§4 — portable on-device speech (iOS + macOS, Apple frameworks, no model download):**
- `audio.synthesizeSpeech` — `AppleSpeechSynthesizeProvider` (AVSpeechSynthesizer) → a WAV `Artifact`;
  honors `voice`/`language`/`speed` via `ExecutionOptions`.
- `audio.transcribe` — `AppleSpeechTranscribeProvider` (SFSpeechRecognizer, on-device) → `.textDelta`;
  requests authorization and fails honestly if denied/unavailable (never silent). `capabilityAvailability()`
  reports STT per the recognizer's authorization status (`ready`/`unsupportedOnDevice`).
- Both wired into `makeDefault`.

**§5 — tool-calling, reasoning, and structured output on the text path (additive, honest):**
- `EshGenerationRequest` gains `responseFormat`, `tools`, `toolChoice`. `EshGenerationEvent` gains
  `.reasoningDelta` and `.toolCall`; `EshGenerationResult` gains `reasoning` and `capabilityResolution`.
- **Structured output** is now resolved in the facade path (native constrained decoding when the backend
  supports it, else an injected instruction; strict + unsupported → typed failure).
- **Reasoning** is separated from the visible answer: live `.reasoningDelta` for the explicit `<think>…
  </think>` format, and an authoritative split (both explicit and implicit-open) on the final result via
  `ThinkingParser`. Plain generation is unchanged when thinking is off.
- **Tools** are accepted and honestly reported via `capabilityResolution` — native local tool-calling is
  not available on esh's on-device runtimes, so `tools` resolve as *rejected* and no `.toolCall` is ever
  fabricated; the `.toolCall` event exists for when a backend natively produces one.
- NOTE: adding `.reasoningDelta`/`.toolCall` to `EshGenerationEvent` means consumers with an exhaustive
  `switch` over it must add cases (or a `default`).

Still staged: §3 macOS-only image/vision/audio/music/video (Python/MLX — needs a separate macOS
capabilities product + a Python-runtime distribution decision).

### SDK — v2.4.0-rc.6 (multimodal capability facade — Phase 1)

Additive to the rc.5 text API (nothing removed or changed for existing consumers). Exposes the EshCore
"UCMR" multimodal contract through the public `EshRuntime` facade so an app no longer has to hand-build a
`CapabilityRegistry`:

- **`EshRuntime.execute(_ ExecutionRequest) async throws -> ExecutionResult`** and
  **`stream(_ ExecutionRequest) -> AsyncThrowingStream<CapabilityEvent, Error>`** (cooperative cancellation,
  same contract as the text `stream`).
- **`EshRuntime.makeDefault(...) async`** — assembles a runtime with the platform text backend(s) **and** the
  portable capability providers wired, so `execute`/`stream` work with no manual registry. GGUF variant:
  `EshRuntime.makeWithEmbeddedGGUF(...) async` (EshLlamaCpp). A bare `EshRuntime()` stays text-only.
- **Portable providers wired (iOS + macOS):** OCR (`image.ocr`, Apple Vision), SVG (`vector.generate`),
  Website/HTML (`webArtifact.generate`), Code project (`project.generate`), and text (`language.*`). Their
  text inference routes back through this runtime — no second inference stack.
- **`capabilityAvailability() -> CapabilityAvailabilitySnapshot`** — honest per-capability states
  (`ready` · `requiresDownload` · `installing` · `temporarilyUnavailable` · `unsupportedOnDevice` ·
  `unsupportedOnPlatform` · `comingLater`); registry-driven so capabilities flip to `ready` as more
  providers are wired.
- Staged for later RCs: §3 macOS-only image/vision/audio/music providers (Python/MLX — need a separate
  macOS capabilities product), §4 portable Apple `Speech`/`AVSpeech` STT-TTS, §5 tool-calling/reasoning/
  structured-output events on the text path. Their capabilities report honestly (`unsupportedOnPlatform`/
  `comingLater`) until wired.

### Packaging — v2.4.0-rc.4 (llama.cpp coexistence)

- **`EshLlamaCpp` can now be linked into an app that already embeds another llama.cpp build** (e.g.
  `LLM.swift`). Both shipped the upstream `llama.framework` / Clang module `llama` / install name
  `@rpath/llama.framework/…`, so linking both produced *"Multiple commands produce llama.framework"* (and, in
  SwiftPM, silent `llama.h` cross-contamination).
- **Fix:** esh's artifact is renamed to an esh-private namespace — framework `esh_llama.framework`, Mach-O
  install name `@rpath/esh_llama.framework/…`, Clang module `esh_llama`, bundle id `technology.fil.esh.esh_llama`
  — by `scripts/namespace-llama-xcframework.sh` (a deterministic post-build transform: `install_name_tool` +
  modulemap + Info.plist ids + ad-hoc re-sign; same pinned llama.cpp bits). **No native symbol prefixing is
  needed**: the artifact is a self-contained *dynamic* framework, and Apple's two-level namespace binds each
  consumer to its own framework's `llama_*`/`ggml_*` symbols, so two distinctly-named llama frameworks link
  and run with isolated state. The bundled dSYMs (also named `llama`) are dropped to remove a second
  collision and shrink the artifact (~96 MB → ~14 MB); Xcode still generates `esh_llama.dSYM` at app build.
- **Consumer-transparent:** public API is unchanged (`import EshRuntime` / `import EshLlamaCpp` /
  `EshRuntime.withEmbeddedGGUF()`); the only internal change is `EshLlamaCpp`'s `import llama` → `import
  esh_llama`. SwiftPM binaryTarget renamed `CLlama` → `EshCLlama`; the artifact is `esh_llama.xcframework`
  and the `binaryTarget(url:checksum:)` points at the `v2.4.0-rc.4` release asset.
- `EshRuntime`-only (Apple-only) consumers are unaffected and still link no llama.cpp.

### Packaging — v2.4.0-rc.3 (portable SDK dependency fix)

- **Split the repo into two SwiftPM packages** so the portable SDK is remotely consumable alongside
  packages that pin a different swift-syntax major (e.g. LLM.swift → swift-syntax 602.x). The root
  `Package.swift` now declares **zero external dependencies** and exposes only `EshCore`, `EshRuntime`, and
  `EshLlamaCpp`; the macOS CLI + runtime (`EshMacRuntime`, `esh`) and their heavy/constrained dependencies
  (**swift-syntax 603.x**, TTSMLX, mlx-audio) moved to a nested `macos/Package.swift` that depends back on
  the portable package by path.
- **Root cause:** SwiftPM resolves the *package-level* dependency graph regardless of which products a
  consumer selects, so declaring swift-syntax 603.x at the root forced it onto every portable consumer and
  made `esh` + `LLM.swift` unresolvable. Removing it from the portable manifest (not just the portable
  target) is the fix. No source/API changes; the macOS CLI and runtime are unchanged.
- Build/test the macOS side with `--package-path macos`; the CLI helper scripts and CI were updated
  accordingly. The `llama.xcframework` binaryTarget now points at the `v2.4.0-rc.3` release asset (identical
  bytes/checksum to rc.2 — the llama.cpp pin is unchanged).

## [2.3.0] - 2026-09-10

**esh 2.3 — generative runtimes as on-demand "engines."** Heavy generative runtimes are no longer bundled or
improvised: they're first-class **installable engines** the user adds on demand, so a fresh install stays
small and large dependencies + model weights land on managed storage (internal by default, the external SSD
when configured). esh owns install / probe / remove, so the web UI and external agents just trigger + track —
they never run `pip` or touch a venv. No runtime/capability contract changes; no Python-bridge changes
(engines install into the venv locations the bridge already discovers).

Highlights:

- **Six installable engines** — `image` (mflux), `sound-fx` (AudioGen), `music` (MusicGen), `upscale`
  (Real-ESRGAN), `remove-bg` (rembg), `diarize` (sherpa-onnx). Each declares its deps, capabilities, size, and
  license; non-commercial engines (AudioGen, MusicGen) are flagged.
- **One-click "Install & continue."** When a capability needs an engine, esh installs it (tracked, with phases)
  and resumes the original request — replacing the v2.2 "run `esh doctor`" setup card. A new **Settings →
  Engines** manager installs/removes engines and shows size, capabilities, storage location, and license.
- **Runtime-aware routing.** The router now probes actual runtime presence, so a request that needs a missing
  engine returns an install step *before* execution instead of failing mid-run.
- **Storage-honoring.** Isolated engine venvs install under the configured assets root — internal or external
  per the user's `esh storage` choice — exactly like models. Everything can run from the internal drive.
- **Agent integration documented.** New `docs/AGENT_INTEGRATION.md`: the capability + engine HTTP contract for
  external clients/agents (route/execute, install-and-resume, engines, storage, guardrails).

### Added
- Generative-engine catalog + manager (on-disk probe, pip install into the main managed env or an isolated
  assets-root venv, safe remove), `EngineInstallManager` phase tracking, and endpoints: `GET /v1/engines`,
  `POST /v1/engines/install` (+ poll/cancel), `POST /v1/engines/remove`.
- Web: engine "Install & continue" flow (studio + routed install-and-resume) and a Settings → Engines manager.
- `docs/AGENT_INTEGRATION.md`.

### Changed
- `IntentResolver` gates heavy capabilities on the engine being installed (`installKind: "engine"`), with an
  injectable probe so install-and-resume stays deterministic in tests.
- The web "needs a one-time setup" card now offers a one-click engine install instead of pointing at
  `esh doctor`.

## [2.2.0] - 2026-09-09

**esh 2.2 — the web studio: Imagine and Sound, dark mode, and honest fresh-install behavior.** A UI-focused
minor release on top of the 2.1 runtime (no runtime/capability contract changes). The local web app grows from
a chat surface into a three-mode studio, and a fresh install now behaves honestly about what needs setup.

Highlights:

- **Imagine mode** — a dedicated image studio: create from a description or drop a photo to edit it, with
  style adapters (incl. generic 3D-animation), a quality-vs-speed control (working resolution), queued
  requests while generating, drag-and-drop / paste, tap-to-enlarge lightbox with zoom/drag and gallery
  navigation, elapsed-time clocks, HEIC photos shown (converted to JPEG on attach), a prettier rounded
  before/after export with an overlaid watermark, and a faint watermark baked into generated images.
- **Sound mode** — a local audio studio: Sound FX (`audio.generate`), Music (`music.generate`), Speech (TTS)
  and Transcribe (STT), each mapped to a real esh runtime with inline playback.
- **Dark mode** — Light / Dark / Auto, in Settings → Advanced; the whole app is theme-aware.
- **Settings → Models** grouped by studio (Chat / Imagine / Sound), with Vision under Chat, SVG under Imagine,
  and Sound linking to Voice.
- **Fresh-install readiness (graceful failures).** Chat, Speech and Transcribe work out of the box. Imagine,
  Sound FX and Music run on optional local engines (mflux, AudioGen, MusicGen) that need a one-time
  command-line setup; when one isn't installed, esh now shows an honest "this feature needs a one-time setup"
  card pointing to `esh doctor` (raw error under "Show details") instead of a bare `pip install …` line or a
  Python traceback. Onboarding no longer promises a "zero-download start" unless Apple Intelligence is actually
  available.

### Added
- **Imagine web studio** (#10–#13): create-from-text and photo-edit paths, Qwen-Image-Edit / FLUX.2 Klein
  backends and generic LoRA/style adapters, quality-vs-speed working-resolution control, request queue,
  drag-and-drop/paste, HEIC display, lightbox (zoom/drag + gallery), elapsed-time clocks, rounded before/after
  export with overlaid + baked-in watermarks, content-derived chat titles, and last-chat restore on refresh.
- **Sound web studio** (#14): SFX / Music / Speech / Transcribe in one mode with inline audio playback.
- **Dark mode** (#16): Light / Dark / Auto in Settings → Advanced; theme-aware palette across the app.
- **Models settings grouped by studio** (#15): Chat / Imagine / Sound sections with sensible per-mode defaults.
- Switching studio mode starts a new chat when the current one has content.

### Changed
- Onboarding's final step promises a zero-download start only when Apple Intelligence is available; otherwise
  it guides the user to install one local chat model first.

### Fixed
- A capability failure caused by a missing optional runtime (mflux / AudioGen / torch+transformers / rembg /
  onnxruntime / sherpa-onnx) now renders as an honest, feature-named setup card instead of a raw error (#17).

## [2.1.0] - 2026-09-07

**esh 2.1 — capabilities, realtime Voice, and generative media.** Promotion of the `2.1.0-rc.2` tree
(behaviorally identical; only this version/changelog change). The rc.2 notarized artifact passed full packaged
validation against the **actual distributed build** (`docs/2_1_RC2_PUBLISHED_AND_VERIFIED.md`) following a
1–2 day real-use soak with no release-blocking regressions. (rc.1 was published then withdrawn after
distribution validation caught a missing packaged worker script; see rc entries below.)

Highlights of the 2.1 line (authoritative status in `docs/2_1_RELEASE_QUALIFICATION_MATRIX.md`):

- **Realtime Voice** (`/voice`) — server-owned VoiceSession with VAD, streaming STT (Parakeet), LLM, and
  sentence-streamed TTS with barge-in and model/voice pickers. Production for English (headphones); RU/HE
  non-production.
- **Universal Capability runtime** — `image.generate`/`edit`/`upscale`/`understand`/`segment`,
  `audio.generate` (neural SFX / AudioGen), `music.generate`, `vector.generate`, `project.generate` (+ Three.js),
  `video.understand`, `STT`/`TTS` — selected by natural-language capability with install-and-resume.
- **`image.edit` → Production** (default FLUX.2 Klein 4B, Apache-2.0; FLUX `kontext` stays Experimental,
  non-commercial). **`audio.generate` → Production** (deterministic DSP + neural AudioGen; the AudioGen model
  is CC-BY-NC-4.0, disclosed). Apple Foundation Models, MLX, and a self-contained static/Metal GGUF runtime.
- **Signed + notarized, self-contained** distribution; offline-capable; managed model storage on external SSD.

### Changed
- Version promoted from `2.1.0-rc.2` to `2.1.0`. No code changes from rc.2.

### Added
- **esh 2.1 UCMR — project.generate reliability pass -> PRODUCTION-READY (untagged).** Closed the "valid files
  but broken project" gap. `ProjectConsistency` (layer 2) adds cheap, conservative, deterministic CROSS-FILE
  checks: JS -> HTML targets (`getElementById('x')` / `querySelector('#x')` must exist — the exact
  `#back-to-top` bug), HTML/CSS -> local assets exist and stay in-bundle (no absolute/dev-machine or `..`
  paths), `.css`/`.js` files must be PURE (not wrapped in `<style>`/`<script>`) and must actually be referenced
  by the HTML (no orphaned/dead stylesheet or script), structure (missing `<body>`, unclosed tags, duplicate
  ids), and unresolved `{{templates}}`. A BOUNDED repair pass (initial generation + at most 2 repairs) feeds
  the structured issue list back to the model and re-validates — accepting a repair only if it strictly reduces
  the problem set, never an unbounded self-fixing loop; a project is saved only as valid when consistency
  passes, otherwise saved and honestly marked invalid. Structured stage-by-stage provenance
  (`metadata.validation`: pathSafety / mimeTypes / entrypoint / contentQuality / crossFileReferences /
  repairAttempts) is exposed for the Execution Inspector. **Evidence-based model policy** (benchmarked on M1
  Pro / 32 GB): Apple FM is the only reliable local option (llama-3.2-3b produced cross-file-broken output,
  deepseek-r1-7b ~8 min + reasoning overflow, qwen3.5-9b crashes in mlx_lm — incompatible, NOT promoted);
  `ProjectComplexity.estimate` sizes the request and Auto selects Apple FM for small projects, and for a large
  one with no compatible larger local model explains/clarifies instead of overflowing (context-window errors
  now return an actionable message, not a raw 400). The decision is exposed in `ExecutionPlan` +
  `metadata.selection`. Warm residency: not applicable to the chosen primary (Apple FM is a system service with
  no esh-side model load; cold ~= warm ~24 s), so left on-demand. Live: 3 projects (landing / dashboard /
  catalog) generated locally, all valid with genuinely resolving cross-file references + correct per-file MIME
  types + working previews. Full suite 519 green.
- **esh 2.1 UCMR — project.generate: text -> multi-file static web project (untagged).** Second slice of the
  ProjectArtifact/web-generation milestone. Text -> a validated, self-contained MULTI-FILE static project
  (index.html + style.css + script.js, referenced by RELATIVE path), a typed `.webProject` artifact previewed
  in the SAME isolated sandboxed iframe as single-file webArtifacts. Pure LLM codegen (quality-first Apple
  Intelligence + JSON-manifest repair, same pattern as vector.generate/webArtifact.generate) -- **no heavy
  models**. Proves the architectural rule again: provider + registration + routing + validation, **no core
  surgery** (project.generate + ArtifactKind.webProject + OutputSpec.project already existed in the contract).
  `ProjectValidator` enforces safety AND quality: drops traversal/absolute/`..`/`~` paths, flags external
  resources, requires a real index.html, and **rejects placeholder/ellipsis content** (some models emit `...`
  instead of writing files) so a degenerate reply fails -> retries -> escalates, and garbage is NEVER saved.
  Artifact files are now served with **per-file content types** (style.css -> text/css, script.js ->
  text/javascript) so a strict (nosniff) browser applies the stylesheet and executes the script. Tier-0 routes
  'multi-file website / web project / static site' -> project.generate without stealing single-file
  webArtifact/SVG/chat (Tier-0 false-exec still 0). **Fit finding:** Apple FM's small (~4 K) context window
  fits a small 2-3 file project but overflows on larger multi-file output ("Exceeded model context window
  size") -- pin a larger local code model (e.g. qwen3.5-9b) for bigger projects; the tier stays honest, failing
  rather than truncating. Live-verified: a 3-file bookshop site generated locally in ~25 s (valid, self-
  contained, relative-linked, correct content types). **The framework/managed-runtime tier (Next.js/Three.js
  with npm + dev-server) remains explicitly DEFERRED** -- running untrusted generated Node code is a separate,
  heavier, security-sensitive tier, not this static bundle. Full suite 510 green.
- **esh 2.1 UCMR — webArtifact.generate: text -> self-contained HTML page (ProjectArtifact primitive) (untagged).**
  First slice of the ProjectArtifact/web-generation milestone. Text -> a validated, self-contained HTML page
  (inline CSS/JS, no network), a typed `.webProject` artifact previewed in an ISOLATED sandboxed iframe
  (allow-scripts, no same-origin/network). Pure LLM codegen (quality-first Apple Intelligence + repair, same
  pattern as vector.generate) -- **no heavy models, fits 32 GB comfortably** (the opposite of the diffusion
  memory ceiling). Proves the architectural rule again: provider + metadata + routing + fit + rendering, no
  core surgery (webArtifact.generate + ArtifactKind.webProject already existed in the contract). Tier-0 routes
  'build a landing page/website/html page' -> webArtifact.generate without stealing SVG/image/chat (Tier-0
  false-exec still 0); Web renders it inline + Open/Download + Execution Inspector. Live-verified: a coffee-shop
  landing page generated in ~35 s (valid 2.8 KB self-contained page, renders correctly: hero + menu + hours).
  Next: project.generate (multi-file Three.js/Next.js -> ProjectArtifact). Full suite 504 green.

### Added
- **esh 2.1 UCMR — image.edit (instruction-based image editing) — EXPERIMENTAL (untagged).** New first-class
  `image.edit` capability (image + instruction -> image) proving the architectural rule: a new capability =
  provider + metadata + routing + fit + rendering, **no core surgery** (image.edit already existed in the
  contract). ImageEditProvider -> ImageEditService -> mflux edit CLIs; backends qwen-edit (Qwen-Image-Edit,
  Apache-2.0, default) + kontext (FLUX.1 Kontext, non-commercial, opt-in); typed ImageArtifact with
  license/model provenance + source-artifact lineage; Tier-0 routing (edit vs segment vs clarify, Tier-0
  false-exec still 0); Install-and-Resume detection; Web before/after compare. **Guarded execution validated
  live**: runs only via /v1/execute (never the raw CLI), killable, --low-ram + memory floor -- the RAM guard
  killed a 768-square run at 4.3 GB free to protect the machine (the safety that, bypassed by a raw CLI run,
  had caused a kernel panic). **Marked EXPERIMENTAL, not production**: no working + memory-feasible +
  accessible model on this 32 GB Mac -- the open commercial-safe Qwen (~40 GB) is too heavy, the official
  Kontext is gated (needs the user's HF license acceptance + token), and the feasible 9 GB community 4-bit
  Kontext produces garbage (silent format incompatibility, verified on real + synthetic images). See
  2_1_IMAGE_EDIT_MILESTONE_STATUS.md. Full suite 498 green.

### Added
- **esh 2.1 UCMR — Stage 3 CLOSED: video.understand fusion made reliable (untagged).** Closes the last Stage 3
  gate. The `video.understand` fusion step (keyframe VLM + audio STT → LLM summary) leaked control tokens from
  the small resident model (`<start_function_call>…` as the answer). It now **prefers Apple Intelligence** for
  the fusion (reliable on-device, no leaks) with a resident-model fallback, **sanitizes** special/control
  tokens (`<|..|>`, `<start_function_call>`, `<eos>`, `<0x..>`, reasoning tags), and **detects degenerate
  output** (escalates, or fails honestly instead of emitting garbage). Live-verified on the same fixture that
  previously produced garbage → a clean coherent summary via apple-intelligence. **STAGE 3 is now COMPLETE**:
  image.generate / image.upscale / video.understand / audio.diarize all production, plus OCR / vector.generate
  / vision / segment / embed·rerank. See `2_1_STAGE3_COMPLETION_REPORT.md`. Full suite 491 green.
- **esh 2.1 UCMR — image.upscale production-qualified (Real-ESRGAN), Stage 3 closeout (untagged).** Turns the
  working Real-ESRGAN ONNX path into a genuinely production capability. **Backend**: pinned model revision
  (`SceneWorks/real-esrgan-onnx@09f741b`) for reproducibility; **alpha preserved** (RGB through the model,
  LANCZOS alpha, recompose — transparent PNGs stay transparent); **tiling with overlap + size-aware memory
  guard** for large inputs (bounds peak memory instead of OOMing); honest metadata (native/effective scale,
  tiled, runtime EP). **Cancellation** (product invariant): `ProcessRunner.runCancellable` /
  `MLXBridge.runCancellable` terminate the helper subprocess on Task cancel (SIGTERM→SIGKILL) — no orphan
  worker; unit-tested. **Benchmark evidence**: `ImageUpscaleBenchmarkRunner` + store persist unified
  `CapabilityPerformanceEvidence`; `POST /v1/capability/image-upscale/benchmark`; wired into
  `CapabilityEvidenceIndex`. **Measured (M1 Pro/32 GB, CoreML EP):** 512@2× ~7 s/3.1 GB, 512@4× ~12 s/10 GB,
  1024@2× ~11 s/3.6 GB, 1024@4× ~24 s/12 GB, 2048@2× ~27 s/8.4 GB; cold≈warm (no warm reuse today).
  **Performance-aware Model Fit** (`ImageUpscaleFitService`): separates memory-fit from expected latency
  (both from measured evidence) — "memory fit does not imply interactive speed" — surfaced in the Execution
  Inspector. **Live-verified** via `/v1/execute` AND the real Web UI: 2×/4×, 800 px tiling, RGBA alpha,
  corrupt-image→typed error, and "Make this better"→clarify (Router Auto safety preserved, no auto-upscale).
  SeedVR2 stays experimental, never auto-selected. Full suite 489 green.
- **esh 2.1 UCMR — Router Auto: ambiguity-gated safe Apple semantic fallback SHIPPED (untagged).** Turns Apple
  Foundation Models into an *abstaining* Tier-1 fallback instead of an eager classifier, so multilingual
  semantic coverage is recovered WITHOUT sacrificing Tier-0's near-zero false-execution. Failure analysis of
  Apple's ~34% false-exec showed 85% were over-eager executions (chat/unsupported/injection force-mapped to a
  capability because the schema had no "not a capability request" option). Fixes, layered: (1) a canonical
  **`abstain`** RouterAction + abstention-first prompt (executeCapability|abstain, "when in doubt, abstain");
  (2) a canonical **`ClarifyKind`** splitting Tier-0's clarify into **`ambiguous`** (≥2 registered
  capabilities plausibly match → clarify, never escalate — capability-driven, not a phrase blacklist) vs
  **`unresolved`** (non-Latin/unfamiliar → may escalate); (3) a **Safety Validator** gating Apple's proposal
  (modality match + a reframed *specific-vs-vague* second pass that vetoes vague quality requests in any
  language). Escalation flow: `Tier-0 → execute | ambiguous→clarify | unresolved→Apple→Safety Validator→
  execute/clarify`; the registry validator still gates every route. **Measured (frozen v2 dataset, 58 cases,
  macOS 26.5.1, M1 Pro): false-exec 0–1.7%** (≤2% ceiling; ~0% on the detail run), **conservative score +0.22**
  (first config to BEAT Tier-0's −0.14), **safe-automation coverage 38% vs 28%**, EN 0.92 preserved, RU 0.55 /
  HE 0.56 recovered (6 correct RU/HE recoveries Tier-0 can't parse), chat 100%. Tier-0 handles 76% of traffic;
  24% (unresolved) reach Apple. **`RouterAutoPolicy` now selects apple-foundation** from `hybrid-gated`
  evidence and the live `/v1/route` runs the gated path (verified live). New: `POST /v1/route/benchmark/detail`
  (per-case failure analysis). All prior evidence preserved (7 versioned rows). Docs:
  `2_1_ROUTER_SAFE_APPLE_FALLBACK.md`, `2_1_CAPABILITY_ROUTER_STATUS.md`. Full suite 479 green.
- **esh 2.1 UCMR — Router Auto live re-benchmark: cold latency + memory, sharper verdict (untagged).** Ran the
  full v2 multilingual dataset (58 cases, EN/RU/HE) through every router on-device (macOS 26.5.1, M1 Pro/32 GB)
  and persisted versioned evidence. The benchmark now records **cold latency** (first call, incl. model load)
  separately from **warm median**, plus **peak process-tree memory**, downloadMB, and OS provenance
  (`RouterEvidence` gains populated `coldLatencyMs`/`memoryMB`/`downloadMB`/`osVersion`; `LatencyBox` splits
  cold vs warm). **Measured verdict: Tier-0 still wins** — no Tier-1 is both safe (≤2% false-exec) and beats
  the instant baseline. Key correction from fresh data: **Apple FM is fast when warm (~2.15 s, not ~13 s — the
  ~12 s is cold-load only), tiny esh-side footprint, and best multilingual (RU 0.64 / HE 0.78)** — its ONLY
  blocker is a **31% false-execution rate**. So the top next experiment is **making Apple FM safe**
  (clarify-biased + abstain gate), NOT fine-tuning FunctionGemma (base capAcc 0, slow, +318 MB). The registry
  validator gates every route, so a mis-proposing router can't cause a false execution through `/v1/route`.
  See `2_1_CAPABILITY_ROUTER_STATUS.md` + `2_1_ROUTER_FINETUNE_PROPOSAL.md`. Full suite 468 green.
- **esh 2.1 UCMR — per-capability model selection + robust vector.generate (development milestone, untagged).**
  Two user-facing gaps closed. **(1) Task models:** Settings → Models now has a **Task models** section where
  you pick which installed model performs each capability — **Chat & reasoning**, **Vector & SVG**, and
  **Vision (images & video)** — or leave it on **Auto**. Options are driven by the real installed models'
  declared capabilities (`GET /v1/capability-models`), never a fabricated list; built-in single-backend tasks
  (image generation → Z-Image, upscaling → Real-ESRGAN, diarization → sherpa-onnx, OCR → Apple Vision) are
  shown as read-only so it's clear why there's no choice yet. Pins persist in `config.toml`
  (`[defaults.capability_models]`, `EshDefaultsConfig.capabilityModels`) and are honored at execution time by
  the capability model resolver and the video frame describer (an unavailable pin falls back to Auto).
  **(2) SVG generation no longer dead-ends:** `vector.generate` asked the resident 3B for strict JSON and
  failed with "The model did not return a JSON scene" whenever the small model's output wasn't parseable.
  It now does a **repair pass** (feeds the bad output back) and **escalates to Apple Intelligence** (on-device,
  JSON-reliable) — Auto is quality-first (Apple FM first, resident as fallback); a user-pinned model is tried
  first instead. **LIVE-verified**: "red rectangle above yellow circle" → valid SVG via `apple-intelligence`.
  Full suite 468 green.

- **esh 2.1 UCMR — Router Auto: evidence-driven semantic capability routing (development milestone, untagged).**
  Makes "which capability does this request want?" a measured, explainable, conservative decision — kept
  strictly separate from Scheduler Auto ("how to execute it"). New: a **v2 multilingual routing dataset**
  (EN/RU/HE, 58 labeled + adversarial/injection cases, versioned) with **asymmetric metrics** (a false
  execution is weighted −6, far worse than a missed capability −2 or an unnecessary clarify −1) and a
  documented conservative score. A **benchmark endpoint** `POST /v1/route/benchmark?mode=tier0|tier1|hybrid|
  apple|apple-hybrid|gemma|gemma-hybrid` runs the dataset with **live** on-device inference and persists
  **versioned evidence** (`RouterEvidenceStore`, provenance + freshness). All routers share ONE canonical
  registry-derived schema (`SemanticRouting`); Tier-1 is pluggable (resident-LLM / Apple Foundation Models /
  FunctionGemma-270m). **`RouterAutoPolicy`** promotes a Tier-1 router only if it is available, fresh,
  ≤2% false-exec, AND beats the free/instant Tier-0 baseline — else Tier-0 + clarification; `/v1/route`
  honors it. **Measured verdict (Apple M1 Pro / 32 GB, full v2 dataset): Tier-0 wins** — no Tier-1 is both
  safe and better. Apple FM is the most accurate (0.70) and multilingual but **36% false-exec** (rejected by
  the safety ceiling) and ~13.6 s/call on-device; FunctionGemma base (capAcc 0) and the resident 3B (capAcc 0)
  can't follow the constrained format; non-resident routers pay ~10 s cold-load per call. A fine-tuned,
  warm-resident FunctionGemma is the plausible future Tier-1 — **proposed, not trained** (`2_1_ROUTER_
  FINETUNE_PROPOSAL.md`). See `2_1_CAPABILITY_ROUTER_STATUS.md` for the comparison table. Full suite 466 green.
- **esh 2.1 UCMR Stage 4.1 — working image upscale backend (development milestone, untagged).** Replaces the
  broken SeedVR2 default with **Real-ESRGAN ONNX** on onnxruntime (CoreML execution provider, torch-free,
  BSD-3) as the default `image.upscale` backend. A new `image-upscale-onnx` bridge op auto-downloads
  `SceneWorks/real-esrgan-onnx` (dynamic-shape x2/x4, 64 MB) to the assets root on demand. The provider gains
  `scale` (2|4) and `backend` options; SeedVR2 stays selectable as **experimental** (never the default).
  **LIVE-verified** via `/v1/execute`: 512→1024 (2×, ~7.5 s) and 512→2048 (4×, ~12 s, peak 10.7 GB) on Apple
  M1 Pro, CoreML EP, typed metadata `{width,height,scale}` + ExecutionPlan, model on SSD, no proc/temp leaks.
  This closes the last open Stage 3 item — **Stage 3 is now complete**. Full suite 431 green.
- **esh 2.1 UCMR Stage 3 — generation & richer media (development milestone, untagged).** New capabilities
  as provider + registration + fit/benchmark + typed result — no core surgery. **Image generation**
  (`image.generate`, text→image) via mflux Z-Image-Turbo 4-bit through an `image-generate` bridge op —
  **verified LIVE** end-to-end over `/v1/execute` (1024×1024 typed PNG artifact with mime/dimensions/
  provenance) on Apple M1 Pro/32 GB. **Image upscaling** (`image.upscale`, image→image) via mflux SeedVR2
  (separate typed capability, VAE-tiled). **Image Model Fit** (`ImageModelFitService`) — resolution-aware
  diffusion memory model reusing the LLM fit language (Comfortable/Fits/Tight/Unlikely/Unknown/Unsupported).
  **Image benchmarks** (`ImageGenerationBenchmark` + runner + JSON store): cold/warm/seconds-per-image/
  peak-memory/resolution/validity/stability with full provenance (model, revision, quantization, runtime,
  Mac, esh version) — designed to feed Scheduler v2/Auto. **Video understanding** (`video.understand`) — a
  multi-provider pipeline: native AVFoundation metadata + adaptive keyframe sampling → VLM per frame,
  native audio→16 kHz WAV → STT, then LLM fusion; exposed as a canonical N-step `ExecutionPlan`
  (`.planResolved` + `ExecutionResult.plan`) with honest rationale (sampled-frame + audio fusion). Audio/
  STT skipped when there's no track; AVFoundation/ImageIO only (no ffmpeg). **Speaker diarization**
  (`audio.diarize`) via sherpa-onnx (onnxruntime, torch-free) — anonymous speaker clusters + time ranges +
  optional STT transcript; chosen over torch-based pyannote. **Web**: plain image-generation requests route
  to `image.generate` in Auto (no manual runtime pick) with a progress indicator, inline artifact render +
  download, and a "Why this execution plan?" inspector. **Resource lifecycle**: large image-model
  downloads route to the assets root (SSD) via `HF_HOME`/`HF_HUB_CACHE`, gated by `ensureAssetsAvailable`
  (never silently fill internal disk); RAM guard refuses/kills generation under genuinely low memory; temp
  frames/audio cleaned per run. Heavy Python deps (mflux, sherpa-onnx) are optional/on-demand — the release
  stays lean. See `2_1_STAGE3_MODEL_PROVENANCE.md`. Full suite 431 green; no 2.0 text/speech regression.
  **Live validation pass** (Apple M1 Pro / 32 GB): image generation LIVE via `/v1/execute` (1024×1024 PNG;
  benchmarked ~215 s warm at 1024², ~51 s at 512², peak RSS 4.4 GB — GPU-compute-bound, memory is not the
  constraint; recorded with recommendation-grade qualifiers). Video understanding LIVE end-to-end on a
  synthetic clip — VLM (nanoLLaVA) reported "red circle (0:00), blue square (0:02)" while STT (parakeet)
  reported "Thursday 3 o'clock", and fusion answered visual-only, audio-only, and combined questions
  correctly with timestamps. Diarization LIVE on 2-speaker audio (2 clusters + time ranges + merged STT
  transcript, sherpa-onnx). Image **upscale (SeedVR2) classified EXPERIMENTAL** — provider wiring, SSD
  storage routing, RAM guard, and graceful error handling validated, but the SeedVR2 backend fails upstream
  on mflux 0.19.1 + mlx 0.32.2 (`mx.repeat` array-repeats API); revisit via newer mflux or a Real-ESRGAN
  ONNX backend. Fixes from the pass: audio materialize extension (WAV was named `.png` → STT failed),
  video VLM loads from the local install path, RAM-guard false-positive on transient pressure removed.
- **esh 2.1 UCMR Stage 2 — vision understanding (development milestone, untagged).** The first real
  non-text INPUT modality: images now actually reach the model. The MLX bridge gained an
  `mlx-vlm-generate` op that loads via `mlx_vlm` (previously `mlx_vlm` was imported only for KV-cache and
  images were dropped); a `VisionUnderstandProvider` (`image.understand`/`image.ocr`, inputs
  `[text, image]`, text output) resolves image attachments (file path or base64→temp) and runs them
  through mlx-vlm. Verified live end-to-end via `POST /v1/execute image.understand` (nanoLLaVA correctly
  read a test image). Note: Qwen2-VL/2.5-VL require a torch-only video processor; torch-free VLMs work
  as-is. Also adds **OCR via Apple Vision** (`image.ocr`, `VNRecognizeTextRequest`) — zero dependency,
  on-device, verified live (read "HELLO ESH 2.1" from an image); and **capability-aware model
  resolution** (`CapabilityModelResolver`) that consumes the previously-dormant `ModelSpec.capabilities`
  so a request without an explicit model picks the right installed model for its capability (vision model
  for image.understand, embedding model for language.embed, …) instead of assuming an LLM. Adds a
  **background removal / segmentation** provider (`image.segment`/`image.edit`, image→image) — the first
  image-OUTPUT provider producing a typed `.image` artifact — via rembg through a new `image-segment`
  bridge op (rembg/onnxruntime optional; graceful error when absent); verified live (background removed
  → transparent RGBA PNG via `/v1/execute image.segment`). And **web typed-result rendering**:
  assistant messages render typed artifacts (image/SVG inline via `/v1/artifacts`, with download; other
  kinds as a file pill) plus an `execCapability` client — verified live rendering an `/v1/execute`-
  generated SVG in the chat.
- **esh 2.1 UCMR Stage 1 — first reference capability providers (development milestone, untagged).**
  Two substantially-different non-text providers prove the capability abstraction end-to-end, with no
  model downloads. **Text→SVG** (`vector.generate`): an installed LLM emits a constrained JSON scene-IR
  that a deterministic Swift renderer compiles to safe, whitelist-only SVG (sanitized values, validated),
  persisted as a typed `.svg` Artifact with static-sandbox preview — verified live via `/v1/execute` +
  `/v1/artifacts`. **Embeddings + Reranking** (`language.embed`/`language.rerank`): ride the already-
  bundled `llama-server` (`--embeddings`/`--reranking`) with zero new dependency (no GPL), producing
  typed `.embedding`/`.ranked` artifacts — embeddings verified live (dim-3072 vectors via the GGUF model
  in embedding mode); rerank unit-tested (live needs a reranker model installed).
- **esh 2.1 UCMR Stage 0 — universal-capability core contract (development milestone, untagged).**
  Additive foundation for the Universal Capability & Modality Runtime, with all 2.0 contracts and
  behavior preserved. New types: `ExecutionRequest`/`ExecutionResult` (typed `inputs[]` + capability +
  desired output + typed `outputs[]`/`Artifact`, not text-only), `CapabilityID` (data, not a closed
  enum), `CapabilityProvider` + `CapabilityRegistry` (dispatched on capability, not model format;
  designed to subsume the speech special-cases), `ExecutionPlan` (single- or multi-step pipelines),
  first-class `Artifact`/`PrivilegeLevel`/`PreviewDescriptor`, and `FileArtifactStore` under a new
  `PersistenceRoot.artifactsURL` (path-traversal-guarded, sha256). New additive HTTP endpoints
  `POST /v1/execute` and `GET /v1/artifacts/{id}`; `language.generate` runs as a real provider bridging
  to the existing text inference path (so text works end-to-end with no change to the 2.0 chat path).
  No new models. 26 new tests; full suite green.

- **esh 2.1 M12 follow-up #1 — shared speech/LLM memory budget (development milestone, untagged).** The
  persistent speech runtime now shares the warm-model pool's memory budget instead of holding memory
  independently. `RuntimeLifecycleManager` reserves the speech runtime's live footprint out of the LLM
  budget, and an LLM that otherwise wouldn't fit reclaims speech (drops the worker) and retries;
  `SpeechRuntimeManager` publishes/clears that reservation on worker load/evict, and the server wires a
  single pool into both LLM inference and speech. Reported via `RuntimePoolStatus.speechReservationGB`.
  Proven on-device (M1 Pro): a resident parakeet worker reserved 2.3 GB; a 1.8 GB LLM against a 1.85 GB
  budget could not fit, reclaimed the worker, and loaded. No web/API/behavior change for existing flows;
  no TTSMLX changes.

- **esh 2.1 M12 (v1) — persistent speech-to-text runtime (development milestone, untagged).** STT no
  longer reloads Python + the model on every request. A new persistent `speech-serve` bridge worker
  loads the STT model once and serves many transcriptions over stdio; Swift `SpeechWorkerProcess` +
  `SpeechRuntimeManager` (lazy start, reuse, model switching, crash-recovery retry, idle eviction) drive
  it, and the server's `/v1/audio/transcriptions` uses it with a one-shot fallback so STT never
  regresses vs 2.0. Measured on M1 Pro: warm STT ~0.14 s vs the one-shot ~4–6 s/call (~30–40×), model
  resident, correct transcription. 2.0 API/behavior contract unchanged. Remaining M12
  (pool memory-reservation integration; warm-TTS folded in) is tracked as a follow-up.

## [2.0.0] - 2026-09-02

**esh 2.0 — local AI runtime.** Promotion of the `2.0.0-rc.7` tree (behaviorally identical; only this
version/changelog change). The rc.7 notarized artifact passed full packaged validation across both
inference backends (see `docs/RC7_PACKAGED_VALIDATION.md`).

Highlights of the 2.0 line (details in the rc entries below):

- **Correct, self-contained GGUF.** GGUF runs through a bundled, static, Metal-accelerated
  `llama-server` (no Homebrew/openssl dependency) driven over its OpenAI endpoint with the model's own
  chat template, so chat terminates at the model's native end-of-turn — no runaway, no hand-rolled
  prompt strings. Native JSON-schema/grammar constrained decoding, streaming, cancellation, caller stop
  sequences, and true weights residency.
- **Correct MLX.** The MLX bridge stops at the model's turn/EOS special tokens, so MLX models no longer
  run away leaking special tokens or hallucinating multi-turn transcripts. Reasoning (`<think>`) is
  preserved. Per-backend structured-output resolution stays honest (strict schema rejected where a
  backend can't enforce it natively).
- **Apple Foundation Models**, on-device speech (STT + TTS), the adaptive scheduler, warm residency,
  and the self-contained Web Chat (folders, inline rename, per-message read-aloud with a mini player,
  audio transcription captions, rich markdown + streaming) — all shipped and validated.

### Changed
- Version promoted from `2.0.0-rc.7` to `2.0.0`. No code changes from rc.7.

## [2.0.0-rc.7] - 2026-09-02

**Release candidate — MLX chat correctness + web polish.** Soaking rc.6 surfaced a second, independent
runaway on the **MLX** backend (analogous to the GGUF one fixed in rc.6). A behavioral change after
rc.6, so a new RC (rc.6 stays immutable). Blocker for final 2.0.

### Fixed
- **MLX chat no longer runs away / leaks special tokens.** The MLX bridge passed the sampler but **no
  stop/EOS configuration** to mlx-lm, so models whose turn-end tokens mlx-lm doesn't catch (e.g. Qwen's
  `<|im_end|>`) ran away emitting chat/EOS special tokens as text (`<|im_start|>`, `<|endoftext|>`) and
  hallucinating multi-turn transcripts. Generation now stops at the model's turn/EOS special tokens and
  never surfaces them (buffered so a marker split across streamed chunks is still caught). Reasoning
  tags (`<think>`/`</think>`) are deliberately preserved — esh parses them. Verified: known-good MLX
  models (DeepSeek-R1-Distill, Llama-3.2) stream cleanly with no leaked tokens and no fake turns.
  (Qwen3.5's remaining plain-text rambling is that model's own incompatibility — it is already **gated**
  from recommendations for 2.0.)
- **Reasoning block no longer blinks while a reply streams.** The streaming bubble was re-created every
  ~40 ms, which replayed the reasoning `<details>` fade/pulse animations. It is now patched in place
  (reasoning text + answer HTML updated on the same nodes), so the "Thinking…" block stays steady.
- **User message bubbles are compact** (already on `main`): the paragraph inside the bubble kept the
  browser-default ~14 px top/bottom margins; scoped to `margin:0`.

## [2.0.0-rc.6] - 2026-09-02

**Release candidate — GGUF chat correctness (runaway-generation blocker).** GGUF replies ran away into
a hallucinated multi-turn `User:/answer` transcript until the token limit, because esh drove
`llama-completion` with a hand-built `User:/Assistant:` plaintext transcript — not the model's chat
format — so the model never emitted its native end-of-turn token. A behavioral change after rc.5, so a
new RC (rc.5 stays immutable). Blocker for final 2.0.

### Fixed
- **GGUF chat now terminates correctly.** esh drives GGUF through a persistent, resident `llama-server`
  over its OpenAI-compatible endpoint with **`--jinja`**, so the model's **own embedded chat template**
  is applied and generation stops at the model's **native end-of-turn** — no esh-side, model-family
  prompt strings, and no runaway. Verified end-to-end on the model that reproduced it: the exact repro
  now finishes naturally (`finish_reason: stop`, ~106 tokens) with no fabricated `User:` turns, and a
  reply that legitimately contains the literal text `User:` is **not** falsely truncated.

### Changed — GGUF backend
- **Persistent, weights-resident GGUF runtime.** The model loads once and stays resident (like the MLX
  persistent worker, owned by the same lifecycle manager); repeat requests reuse it (~0.16 s warm) with
  no per-request model reload.
- **Native structured output for GGUF.** Strict `json_schema` / `json_object` / GBNF grammars are
  enforced natively via llama.cpp constrained decoding (a backend without native support still honestly
  rejects a strict request rather than approximating). The old blanket "json_schema not exposed" gate is
  removed; `response_format` is now resolved per-backend and forwarded to the runtime.
- **Caller stop sequences** (`stop`) are honored, in addition to the model's native end-of-turn.
- Streaming, cancellation (the resident server survives an aborted request), multi-turn history, system
  prompts, and inline reasoning (`<think>`) all verified through the server path.

### Changed — build & packaging
- `scripts/build-llama.sh` now builds a self-contained static **`llama-server`** (pinned llama.cpp
  `b8660`, `GGML_BACKEND_DL=OFF`, embedded Metal, `LLAMA_OPENSSL=OFF`) instead of `llama-completion`;
  `package-release.sh` bundles it, the packaged smoke test guards it, and the packaged runtime points
  `ESH_LLAMA_CPP_SERVER` at it. Still fully relocatable — no Homebrew/openssl dependency (rc.4 packaging
  guarantees preserved).

## [2.0.0-rc.5] - 2026-09-01

**Release candidate — web chat soak fixes.** Web-client polish and organization found while soaking
rc.4; no engine or packaging changes (the rc.4 GGUF fix stands).

### Added — web chat
- **Folders for chats.** Group conversations into collapsible folders: create one with the new-folder
  button beside "New chat", **drag chats into a folder** (or back out to Recent), and right-click a
  folder to rename or delete it (deleting a folder returns its chats to Recent, never deletes them).
- **Inline rename.** Renaming a chat or folder now edits the title **in place** — a focused input,
  Enter to commit, Escape to cancel — instead of a popup dialog.
- **Mini read-aloud player.** Playing a message aloud now shows a compact player above the composer —
  a synth/loading state, play/pause, a live progress bar, and a stop button.
- **Audio transcription is shown as a caption.** A sent voice clip shows a "Transcribing…" indicator
  while speech-to-text runs, then its transcription appears as a muted caption under the clip — clearly
  distinct from text you typed. (The model still receives the transcript.)

### Changed — web chat
- **Assistant replies no longer speak automatically.** Text chat was auto-playing every response as
  audio (and re-loading the TTS model per response, which grew memory). Speech is now **manual and
  per-message**: a small read-aloud button under each assistant message plays that reply on demand and
  shows loading → playing state; the automatic "Read responses aloud" toggle is removed. One clip
  plays at a time and its audio URL is released when it ends or is stopped, so repeated use never
  leaks memory. (Voice mode still speaks automatically, as before.)
- **Tighter message layout.** User message bubbles use less vertical padding, the assistant footer
  (read-aloud + timing) is more compact, and the read-aloud icon is aligned to the text.

### Fixed — web chat
- **Popovers no longer "jump" while a reply streams.** The menu entrance animation was replaying on
  every full re-render (streaming start/end) instead of only when the popover opens; it now animates
  once, on the open transition. The Engine panel also centers with a margin instead of a transform, so
  the entrance animation can't shift it sideways.
- **Streaming cursor sits inline.** The blinking cursor now appears at the end of the last line of the
  streaming reply instead of dropping onto its own line below the text.
- **A model that can't load now shows a friendly card.** When a selected model fails to load (for
  example its files are no longer on disk), the chat shows a clear "This model isn't available" card
  with **Try again** / **Continue with Auto** — instead of a raw `[error]` line rendered as a normal
  reply (with a read-aloud button).

## [2.0.0-rc.4] - 2026-09-01

**Release candidate — GGUF packaging fix.** Packaged validation of rc.3 found GGUF inference broken
on the notarized artifact: the bundled `llama-cli` crashed at dyld (its dylibs were not bundled) and,
deeper, modern Homebrew llama.cpp/ggml dlopens its compute backends (Metal/CPU/BLAS) from
`/opt/homebrew` at runtime — so GGUF could never work on a clean machine. A behavioral change after
rc.3, so a new RC (rc.3 stays immutable). MLX, Apple Foundation Models, speech, and the web client are
unchanged from rc.3.

### Fixed
- **GGUF works from the packaged, notarized build.** The release now bundles a **self-contained
  `llama-completion`** built from a pinned llama.cpp revision (`b8660`) with static ggml, embedded
  Metal shaders, and dynamic backend loading **disabled** (`GGML_BACKEND_DL=OFF`) — no dlopen, no
  Homebrew, no OpenSSL. It links only system frameworks (Metal/MetalKit/Accelerate/Foundation), so
  GGUF generation runs with Metal acceleration on any Apple Silicon Mac with zero external
  dependencies. Verified in a clean environment: correct output, Metal active, ~46 tok/s on an M1 Pro,
  no per-call latency regression (the first GGUF call on a machine pays a one-time Metal shader
  compile; steady-state Metal load is ~0.01 s).
- The packaged runtime now points at the bundled `llama-completion` (the non-interactive completion
  binary the GGUF backend drives) instead of the interactive `llama-cli`, which recent llama.cpp
  builds reject for one-shot completion.

### Changed — build & CI
- New `scripts/build-llama.sh` builds the self-contained binary; `scripts/package-release.sh` bundles
  it (and refuses to package a binary with any non-relocatable dependency). CI and the release
  workflow build it (cached on the pinned revision) instead of `brew install llama.cpp`.
- The packaged smoke test now guards the GGUF runtime directly — the bundled binary must exist, be
  relocatable (no `@rpath`/Homebrew/ggml/llama deps), and launch without a dyld crash. This is the
  check that would have caught the rc.3 regression.

## [2.0.0-rc.3] - 2026-09-01

**Release candidate — composer redesign.** A behavioral/visual change after rc.2, so a new RC
(rc.2 stays immutable).

### Changed — composer (matches the approved v2 design)
- **The model picker moved into the composer** as a chip (`Auto ▾`), and the top-right header is now
  just sidebar + brand + settings. The picker popup opens upward, anchored to the composer.
- **New Effort chip** beside it opens a Faster↔Smarter popover (Off / Low / Medium / High). It is the
  reasoning control at the point of use, synced with Settings → Intelligence: **Off** disables the
  reasoning pass; Low/Medium/High reason. This also fixes the mic/send controls looking orphaned in
  the composer.

### Added
- **Message queue.** Queue a follow-up while the assistant is responding with **Option+Enter** (or
  Cmd/Ctrl+Shift+Enter), or the discoverable **queue button** that appears next to Stop during
  generation; queued messages show as removable pills and auto-send in order once it's free (a manual
  **Stop** does not auto-continue). Conventional chat keys are preserved: **Enter** sends,
  **Shift+Enter** is a new line, **Cmd/Ctrl+Enter** also sends.
- **Faster voice replies.** The voice loop now streams the answer and synthesizes/plays it
  sentence-by-sentence, so speaking begins after the first sentence instead of after the whole reply
  (each sentence's TTS overlaps the previous one's playback). Time-to-first-audio drops from
  full-generation + full-synthesis to roughly one sentence. (esh already uses TTSMLX for synthesis; a
  persistent/warm TTS synthesizer to cut the per-call model-load floor is a possible follow-up.)
- **Rename/delete chats.** Right-click a conversation in the sidebar for a Rename / Delete menu.
- **Voice model selection.** Settings → Voice now has functional dropdowns fed by the real audio
  catalog (`GET /v1/audio/models`): **Voice model** (Soprano, Pocket TTS, Orpheus, VyvoTTS, Qwen3 TTS —
  known-broken models like Marvis are excluded), **Voice** (the selected model's real speaker voices),
  **Language** (the selected model's real languages, incl. Qwen3 TTS's 15), and **Speech-to-text**
  (verified Parakeet default + a Custom option for any mlx_audio STT repo). Selections persist (TTS
  model + STT to esh config; voice/language as browser prefs) and are sent with each speech request; a
  summary line shows the active pair. No fabricated model names — everything comes from real
  capabilities, and speech models download on first use.

### Fixed
- **Composer layout + controls.** The composer is now a column so the input fills the row and the model
  (`Auto ▾`) and effort chips sit flush-right (they no longer float mid-bar), and pending attachments
  stack as chips above the input. The chips toggle closed on re-click and any open popover closes on an
  outside click; the effort slider is draggable (not click-only); and focus returns to the text field
  after picking a model/effort or closing a popover.
- **Attachments in chat.** Sent files now show as a pill in the message bubble (documents/text too, not
  only image/audio), and text/document contents are decoded and included in the model request so the
  model actually reads the file (verified: it summarized an attached `.txt`).
- **Voice no longer flickers while speaking.** The spoken answer reveals by updating a single node
  instead of re-rendering the whole page each word; the voice-error stage got a clearer layout and
  buttons.
- **Hands-free voice.** The voice loop now advances automatically — listening ends on a short pause
  (silence detection), then think → speak → listen, with no tapping required (tapping the circle to
  finish early / the wave to interrupt still works). Falls back to tap-to-finish if the Web Audio API
  is unavailable.
- **Composer keeps focus after sending.** Focus returns to the text field once a response completes,
  so you can type the next message immediately. (A trailing throttle render was rebuilding the
  composer and dropping focus.)

## [2.0.0-rc.2] - 2026-09-01

**Release candidate — the approved 2.0 Web Experience.** A faithful, warm-paper redesign of `esh web`
into the primary browser interface, implemented as a **thin client** over canonical esh endpoints
(no routing/fit/scheduler/policy logic in the browser).

### Added — Web Experience
- **Design language:** warm paper (#fbfaf8) + graphite ink (#201e1b), inline SVG icons (no emoji),
  IBM Plex Mono for technical data, amber only for warnings.
- **Canonical data endpoints:** `GET /v1/engine` (host/memory/storage/engines/Apple), `GET /v1/schedule`
  (Scheduler decision + rationale), `GET /v1/catalog` + `/v1/catalog/{id}` (recommended catalog with
  real ModelFitService fit + measured-vs-estimated), `GET`/`POST /v1/config`, and
  `POST /v1/models/install` (+ status/cancel).
- **Onboarding** on first run with real Mac detection; **model picker** with Auto routed through the
  real Scheduler (shows the live pick); **model browser** with honest fit + gating (incompatible
  models shown, never installable) + install with live progress/cancel/error/retry.
- **Per-response execution truth:** a final `esh_execution` SSE frame carries the real ExecutionProfile
  (server TTFT, output tokens, residency, KV/prompt-cache strategy, optimizer). The Execution panel
  and **"Why this model?"** show the actual response, not a re-simulation.
- **Engine Inspector** and **Storage** view from real `/v1/engine` data; **Settings** persist
  canonically to config (perf mode) with browser-local presentation prefs only.
- **Real voice loop:** mic → STT (`/v1/audio/transcriptions`) → LLM → TTS (`/v1/audio/speech`), with
  honest degradation when the mic or a speech model is unavailable.
- **Attachments** as prototype-faithful chips (sent when the model supports them, never silently
  dropped); **degraded model-failure** card (what happened / what still works / what to do);
  streaming with live reasoning, math rendering, typing indicator, stop, and token-limit note.
- **Fluid animations** (popup/drawer/modal entrances, one-time message fade-in, hover/press) and
  **accessibility basics** (keyboard nav, Escape-to-close, focusable + ARIA-labeled controls,
  `prefers-reduced-motion`).

### Refined
- **Model picker** now uses one consistent row pattern — rounded highlight + right-aligned check on
  the selected row, hover tint on the rest — across Auto, Installed, Apple Intelligence, and
  Optimize-for (radios removed), in the approved section order.
- **Status line under the composer** is contextual: it surfaces what matters right now (e.g. amber
  “External storage disconnected”, “Local · <model> · generating”, “… warm”, “Local · Private · Ready”)
  from real engine/storage signals, and still opens the Engine menu.
- **Voice is a full conversational loop** — listening (pulsing circle) → thinking (three dots, the
  utterance settles into a muted quote) → speaking (waveform + the answer streams in sync), then back
  to listening. Two round 44px controls (keyboard = back to text, dark X = end); every finished
  exchange is committed to the transcript with a `voice · Xs · Y tok/s` footer.
- **Settings** completed to all eight panes: General (Send-with-Enter, Save history, Clear history),
  Intelligence (Auto routing, Reasoning, System instructions applied per new conversation), Models
  (installed list + storage), plus Voice/Performance/Storage/Privacy/Advanced.

### Notes
- Full voice (real mic + STT) and packaged `esh web` are validated on the notarized RC artifact.
- `qwen3.5` remains catalog-gated (`.incompatible`); observed generating malformed output via the
  persistent worker path — flagged for the compatibility review.

## [2.0.0-rc.1] - 2026-09-01

**Release candidate — not production-stable 2.0.** Published as a GitHub prerelease; the stable
Homebrew cask is intentionally NOT updated by RC tags, so `brew` stable users are not auto-upgraded.

### Version story
- `0.9.8` existed only as an **unreleased repository version** (VERSION bump + streaming/residency work
  on `main`); it was never tagged or distributed. The latest **public stable** release before this RC
  was **`0.9.7`**. The 0.9.8 work is folded into this RC rather than published as a standalone release.

### Added
- **Rich, ChatGPT-like Web Chat** (`esh web`): multi-conversation history (localStorage), model picker,
  settings (system prompt, temperature, max tokens, reasoning, cache/compression, auto-TTS),
  collapsible reasoning, markdown + image/audio rendering, attachments, per-message TTS, and mic upload.
- **`POST /v1/audio/transcriptions`** — on-device speech-to-text endpoint (wired to `SpeechToTextService`).
- **Cross-backend capability matrix** (`2_0_COMPATIBILITY_MATRIX.md`) and 2.0 RC audit/report docs.
- **Graceful port-conflict handling** for `esh web`/`esh serve`: offer to stop an existing esh server,
  move to a free port, or cancel (auto-selects a free port when non-interactive) instead of failing.

### Fixed (compatibility blockers)
- **B1 — no known-broken default/recommended model.** All MLX Qwen 3.5 models (hybrid architecture,
  reproducibly crash on the current mlx-lm) reclassified `.incompatible` and excluded from
  recommendations; the flagship default is now **Mistral Small 24B**. `esh model recommended` hides
  incompatible models by default (`--all` to show).
- **B2 — Marvis TTS** (fails to load) is filtered from the advertised audio catalog; an explicit
  request returns an honest 400 instead of crashing.
- **B3 — GGUF backend works on current llama.cpp.** Recent llama.cpp removed `--no-conversation` from
  `llama-cli`, which made every GGUF run hang. esh now uses `llama-completion`; verified text
  generation and native strict JSON-schema constrained decoding end-to-end.

### Security / hardening
- Request-body size cap (rejects an over-large `Content-Length` with 400).
- Wildcard-bind warning when serving on `0.0.0.0`/`::` (recommends `--api-key`).
- Security & privacy review (`2_0_SECURITY_PRIVACY_REVIEW.md`): no telemetry, on-device inference,
  loopback-by-default. No high-severity findings.

### Verification status
- **Verified (real runtime):** MLX inference, persistent residency (~10× warm, no orphans), scheduler
  routing around broken models, GGUF text + strict JSON, TTS (real WAV), 313 automated tests.
- **Unit-only / plumbing-verified:** STT endpoint (real transcription needs the packaged `mlx_audio`),
  Terminal UX TTY interaction, Web Chat live-browser interaction.
- **Environment-limited (not yet validated):** live browser, live mic capture, fresh clean machine,
  packaged cross-version upgrade, multi-hour soak. See `2_0_RELEASE_REPORT.md`.

### Known incompatible models
- MLX Qwen 3.5 family (`qwen-3-5-9b`, `-optiq`, `-2b`, `-0-8b`, `-0-8b-optiq`, `-27b-opus-distilled`):
  crash on current mlx-lm; gated. `qwen-3-5-9b-gguf` is experimental (unverified). Marvis TTS: gated.

## [0.9.8] - 2026-09-01

### Fixed
- **Real incremental streaming for `esh serve` / Web Chat.** Streaming chat completions previously
  generated the entire response, then chunked it — so the Web Chat showed nothing until generation
  finished (a long pause on reasoning models). The server now streams tokens as they are produced
  (per-token SSE deltas written incrementally over the connection). Verified: chunks spread across the
  whole generation window, not bunched at the end.
- **`esh web` keeps MLX models weights-resident** (persistent worker) so the first token arrives in
  ~0.1s instead of after a per-request model reload. Opt out with `ESH_MLX_PERSISTENT=0`.

## [0.9.7] - 2026-08-31

### Added
- **`esh audio converse <audio>` — one voice round.** Transcribes the input (speech model), gets a
  reply from the language model, and speaks it (speech model) — switching between the language and
  speech models via esh primitives, using the configured STT/TTS and a resolved LLM. Verified
  end-to-end (`hello.wav` → "Hello from Esh." → LLM reply → spoken WAV). Continuous mic-driven
  conversation is the next extension.

## [0.9.6] - 2026-08-31

### Fixed / Added (Terminal UX + speech, from real-use feedback)
- **Reasoning is now detected and collapsible.** The parser only recognized an explicit
  `<think>…</think>`; models like DeepSeek-R1 are primed with `<think>` by their chat template, so the
  whole chain (and a stray `</think>`) leaked into the answer. It's now correctly split into a
  **Reasoning** section that collapses to a one-line summary by default; `/think` toggles expansion.
- **Slash-command autocomplete.** Typing `/` (or `/mo…`) shows a live suggestion panel of matching
  commands with descriptions.
- **Configurable, persisted speech models.** `esh config set-speech --tts <id> --stt <id>` persists
  your choices; `esh audio speak` / `esh audio transcribe` use them by default (explicit `--model`
  still wins) — set up STT/TTS once and switch between them.
- The `prompt_cache[0].offset` crash from the screenshots was fixed in 0.9.3 (`ArraysCache` has no
  `.offset`); upgrading resolves it. qwen3.5-9b has a separate mlx-lm architecture incompatibility the
  scheduler routes around (measured evidence). Thinking/tools capability resolution is honest per
  backend.

## [0.9.5] - 2026-08-31

### Fixed
- **Text-to-speech works out of the box.** The historical default TTS model (Marvis) fails to load on
  the current TTSMLX version (RoPE-key mismatch), so `esh audio speak` with no `--model` now prefers a
  known-working default (`Soprano-80M`, verified). This closes the full **audio → STT → LLM → TTS**
  loop end-to-end. Marvis stays selectable as a model-specific known issue (SPEECH_REPORT.md).

## [0.9.4] - 2026-08-31

### Added
- **First-class Terminal UX status.** The chat status line now shows a per-turn execution summary
  (`1.8s · 927 tokens · 38 tok/s · KV hit`), the footer surfaces realized KV hit/miss + peak memory,
  and new slash commands `/status`, `/context`, `/performance`, `/auto` (what the scheduler would
  pick), and `/clear`. Formatting/parsing is pure and unit-tested; interactive behavior needs a TTY.
- **M8.5 Web Chat.** `esh web` launches the local esh server and opens a self-contained, single-file
  browser chat client (served at `GET /web`) over the canonical esh APIs (`/v1/models` + streaming
  `/v1/chat/completions`, same-origin, no external assets): model picker, streaming, Stop/cancel. A
  reference client, not another inference engine. Server side verified via curl.
- **M10 Speech-to-text.** `esh audio transcribe <file>` — on-device STT via mlx_audio (default
  `parakeet-tdt-0.6b-v2`), symmetric with the MLX TTS path; replaces the old "not wired yet" stub.
  Verified end-to-end (`hello.wav` → "Hello from Esh."), including an audio → STT → LLM pipeline.

### Notes
- Hardening pass (HARDENING_REPORT.md): 11 shipping surfaces smoke-verified on the real binary. Two
  model/runtime version mismatches recorded truthfully — qwen3.5-9b (mlx-lm) and the Marvis TTS model
  (RoPE key); see SPEECH_REPORT.md. Not 2.0.0 yet, by evidence.

## [0.9.3] - 2026-08-31

### Added
- **Model Benchmark Lab.** `esh benchmark lab [--all | <ids>]` measures installed models through esh's
  own inference path (not a duplicate framework): deterministic quality probes (math / instruction /
  structured / coding / general, fair to reasoning models via `<think>` stripping + thinking budget)
  plus real runtime performance (TTFT, decode tok/s, peak memory), stored as a **versioned,
  provenance-stamped** dataset. It computes profile leaders (Fast / Low-Memory / Reasoning / Coding /
  Maximum Quality) and feeds `esh model recommended --explain`, which now marks benchmarked models
  **“★ measured on your Mac”** — local measured evidence overriding curated estimates. See
  MODEL_BENCHMARK_LAB_REPORT.md.
- **Adaptive Scheduler revalidation.** `esh schedule` now ranks on the Benchmark Lab dataset: measured
  goal-specific quality replaces the parameter-size proxy, measured decode tok/s rewards fast requests,
  and a model measured as **failing to run is deprioritized and called out**. Demonstrated: a
  high-quality request selects the working 3B and **skips a larger catalog-recommended model the lab
  measured as broken** — adaptive selection beating the naive size default.

### Fixed
- **Free-space reporting on non-APFS (ExFAT) external volumes** returned 0 (`…ForImportantUsage` is
  APFS-only), reporting a full disk and blocking downloads / Model Fit. Now falls back correctly.
- **MLX bridge crash on newer cache types** (`ArraysCache` has no `.offset`) → safe fallback.

## [0.9.2] - 2026-08-31

### Added
- **Apple Foundation Models as a first-class routable backend.** `esh infer --model apple-intelligence`
  runs the on-device Apple system model through the canonical inference path (`backend: apple`, honest
  capability resolution). Safety guarantees, tested: never auto-substituted (routes only on an
  explicit reserved id — `apple` / `apple-intelligence` / `apple-foundation`; a normal/unknown id can
  never match one); on-device only via `SystemLanguageModel.default` (never PCC/cloud, so `localOnly`
  is safe); strict structured output rejected, non-strict approximated, reasoning ignored, responses
  returned whole — all surfaced honestly, none faked. Verified with real on-device generation. A
  scored Apple scheduler candidate is deferred to the Scheduler Revalidation milestone.

## [0.9.1] - 2026-08-31

### Added
- **M8 contract — remaining gaps closed.** Realized prompt-cache state as a first-class, honest
  execution signal (`cacheHit` + `cachedTokens` reused on `Metrics`/`EshUsage.cachedInputTokens`/
  `ExecutionProfile.cacheHit`, distinct from the chosen strategy). Typed `EshAttachment`
  (image/document/audio) on requests, resolved honestly as rejected — never silently dropped — with a
  reason distinguishing a model-capability gap from an esh-execution gap. **Apple Foundation Models
  participate in the capability contract** (`esh capabilities` → `appleProvider`): honest
  availability, on-device-only by construction (`permitsCloudOrPCC=false`, `neverAutoSelected=true`),
  limitations listed not hidden. A consolidated cross-backend M8 conformance suite. See
  M8_CONTRACT_REPORT.md (M8 honesty contract now substantially complete; making Apple a
  routable/schedulable backend is deferred as a design decision).

## [0.9.0] - 2026-08-31

### Added
- **Persistent, weights-resident MLX runtime (true residency).** A new `mlx-serve` worker loads a
  model ONCE and serves many requests over a newline-delimited JSON protocol, so MLX "warm" can mean
  weights actually stay in memory instead of reloading per request. Owned by the existing
  `RuntimeLifecycleManager` (no parallel manager): streaming, cancellation, crash detection +
  automatic restart, graceful unload, idle/memory-pressure eviction, bounded concurrency, and clean
  shutdown — with no orphan workers (a worker exits when esh does). Truthful residency + health are
  surfaced through pool status and `ExecutionProfile.residency`. Opt-in via `ESH_MLX_PERSISTENT=1`
  until a stability soak justifies default-on. Benchmarked ~13× faster warm requests (0.24s vs 3.28s
  reload-per-request) on qwen2.5-0.5b; savings scale with model size. See PERSISTENT_RESIDENCY_REPORT.md.
- **Inference Contract v2 (M8) progress.** Canonical tools (`EshToolDefinition`/`EshToolChoice`/
  `EshToolCall`) and normalized usage (`EshUsage`) with **measured** input/output/total tokens from
  the MLX runtime (never fabricated; local monetary cost = 0 with provenance). **Native constrained
  decoding on GGUF (llama.cpp)** — strict `json_schema`/`grammar` resolve to `.applied` and are
  enforced via `--json-schema`/`--grammar`; MLX/ONNX honestly report `.approximated`/`.rejected`
  (no silent prompt-instruction substitution). Honest per-backend reasoning capability resolution.
  A canonical streaming event model (`EshStreamEvent`) with a real text-stream adapter. See
  M8_CONTRACT_REPORT.md (M8 is advancing, not yet complete).

## [0.8.1] - 2026-08-31

### Fixed
- **Critical: packaged-binary runtime discovery when invoked as a bare command.** Bundled-runtime
  resolution (MLX `mlx_vlm_bridge.py`, `llama-cli`, TurboQuant helper, TTS metallib) and `VERSION`
  lookup were keyed off `CommandLine.arguments[0]`. Under a PATH/shim invocation — the normal
  `esh …` Homebrew case — `argv[0]` is often the bare command name and resolves against the current
  working directory, so the packaged root came back `nil`: `ESH_MLX_VLM_BRIDGE` was never set and
  MLX inference failed pointing at a build-machine path (`/Users/runner/work/esh/…`), while
  `esh version` reported `unknown`. All executable-relative lookups now resolve the true image path
  via `_NSGetExecutablePath`. Verified end-to-end: bare `esh` from an unrelated directory now
  resolves the version and runs MLX inference (0.8.0 fails the same invocation).
- Homebrew cask: use the non-deprecated `depends_on macos: :ventura` symbol form.

## [0.8.0] - 2026-08-31

### Added
- **Runtime Lifecycle / Warm Pool (M7).** A backend-agnostic `RuntimeLifecycleManager` above MLX/llama.cpp/Apple: loaded-model registry with per-model state (unloaded/loading/warm/active/idle/unloading/failed), concurrent-load dedup, a unified-memory budget with configurable safety + TTS reserves (text+speech coexistence), idle-timeout and memory-pressure eviction (LRU) with over-budget refusal, bounded concurrency with interactive-over-background priority, cancellation, and prewarming. `esh serve` runs with a shared pool; the Adaptive Scheduler is resource-aware (an already-warm model wins close calls, recorded in the rationale). **Truthful residency:** the pool tracks/reports `RuntimeResidency` (`weights-resident` vs `handle-cached`). Real-runtime measurement confirmed today's MLX (subprocess-per-generate) is **handle-cached, not truly weight-resident** — `warm` means a handle is available, and callers must read `residency` for true warmth. Memory distinguishes estimated vs measured. See RUNTIME_LIFECYCLE_REPORT.md. Follow-up: a persistent MLX bridge for real weight residency.

## [0.7.0] - 2026-08-31

### Added
- **Model Benchmark Lab v1 (recommendation engine).** `esh model recommended --explain [--profile] [--json]` produces fit-aware, per-profile recommendations for this Mac (general/coding/reasoning/fast/low-memory/long-context/tools/best-quality) over a versioned dataset schema. Rankings exclude models that don't fit, prefer comfortable/fits, and are honestly labeled `estimated` unless you've locally benchmarked the model — in which case your measured decode speed supersedes/annotates the ranking (`measured-local`). No fabricated quality numbers. Candidate discovery is researched live. See MODEL_BENCHMARK_REPORT.md.
- **Execution transparency.** Inference responses now include an `executionProfile` reflecting the KV/prompt-cache strategy that actually ran, for the Scheduler / Web Chat / Terminal UX.
- `docs/GAP_AUDIT.md`: honest audit documenting which milestones are complete vs. slices (M7/M8/structured-gen/cache/update/apple).

## [0.6.0] - 2026-08-31

### Added
- **Adaptive Intelligence Scheduler v1 (M9).** `esh schedule` takes a capability request under constraints — `--goal general|coding|reasoning|structured --quality high|balanced|fast --latency interactive|batch --context N --tools --vision` — and picks the best installed model + optimization plan for this Mac, recording the rationale (`--json` for tooling). It composes catalog capabilities, per-model fit, and the M1 optimizer's benchmark evidence: it filters by required capabilities, excludes models that don't fit, ranks by fit then quality-aligned size, and derives the performance mode (dropping to `memory` for tight fits). When no installed model satisfies the request it *suggests* Apple Intelligence (only for modest, tool-free requests) or installing a model — a suggestion, never a silent substitution. (Live memory-pressure/warm-pool state is an M7 input, taken as a parameter for now and noted honestly.)

## [0.5.0] - 2026-08-31

### Added
- **Structured output + honest capability resolution (Inference Contract v2, first slice).** The native infer contract gains `response_format` (text / json / json_schema / grammar). `esh infer --response-format json [--json-schema <path-or-text>]` and the JSON response now include a `capabilityResolution` block reporting exactly how each requested option was handled — `applied` / `transformed` / `ignored` / `rejected` — so esh never silently pretends an unsupported option was honored. json/json_schema are approximated via an injected instruction (clearly labeled "not guaranteed" since MLX has no native constrained decoding); grammar is `rejected`. Backward-compatible: pre-existing infer request JSON still decodes.

## [0.4.0] - 2026-08-31

### Added
- **Apple Intelligence generation.** `esh apple <prompt> [--system …]` runs the on-device Apple Foundation Models system model with zero model downloads; `esh apple status [--json]` reports availability. Guarded so it compiles/runs without the FoundationModels SDK, throws clearly when unavailable, and is never used to replace an explicitly requested MLX/GGUF model. (Full provider integration into the capability contract is planned for a later milestone.)
- **`esh update check [--json]`.** Explicit update-check surface with a documented notify-only policy — esh reports a newer release (`brew upgrade --cask esh`) but never installs an executable update itself (`autoInstall: false`).
- `docs/ROADMAP_STATUS.md` tracking milestone status against the delivery roadmap.

## [0.3.0] - 2026-08-31

### Added
- **Optimization Foundation (M1).** A pluggable optimization boundary: strategies (KV-cache incl. TurboQuant, prompt cache) are data behind `OptimizationStrategy`; the `OptimizationPlanner` produces a serializable `ExecutionProfile`. A benchmark harness runs strategies through the **real** inference path and persists raw results keyed by hardware/model/backend/runtime; `auto` selects a non-baseline strategy only with local measured evidence that clears a quality floor (applied in every mode). New `esh performance <auto|speed|balanced|memory>` and `esh optimize status|strategies|plan|benchmark|compare|reset` (all `--json`). See OPTIMIZATION_REPORT.md and docs/OPTIMIZATION.md.
- **Pre-download model-fit gate.** Before downloading multi-GB weights, esh estimates fit against chip/unified-memory/context/disk/storage and classifies it comfortable/fits/tight/unlikely/unsupported/unknown with a memory breakdown and rationale. Soft gates (tight/unlikely/unknown, insufficient disk) require confirmation or `--force`; only genuine technical incompatibility or an unavailable storage volume is blocked. esh never substitutes a different model. New `esh model fit <model>`.
- **Apple Foundation Models detection.** `esh doctor` and `esh onboard` report Apple Intelligence (Apple Foundation Models) availability as a zero-download on-device provider (available / deviceNotEligible / appleIntelligenceNotEnabled / modelNotReady / unsupported), distinct from Private Cloud Compute. Full inference integration is planned for the Capability API / Scheduler milestones.

### Changed
- `ModelInstallPreflightService` no longer hard-blocks installs on predicted memory/disk pressure — memory is a soft fit gate so knowledgeable users can still try a model; only unsupported format/architecture blocks.

## [0.2.0] - 2026-08-31

### Added
- **External-SSD storage.** Large AI assets (model weights, GGUF files, TTS voices, caches, downloads) can live on an external volume while lightweight config/state stays on the internal disk. `esh storage show|set|use-internal|doctor|migrate` (human + `--json`). A volume-marker scheme detects a disconnected drive and fails with a clear "Model storage volume is unavailable" error instead of silently re-downloading huge assets to the internal disk. `ESH_ASSETS_HOME` overrides the assets root.
- **Guided onboarding.** `esh onboard` detects the Mac (chip/RAM/macOS/engines), chooses storage, recommends a hardware-matched model, installs it, and finishes with next steps. Safe to re-run; `--status` (non-interactive summary) and `--yes` (auto-install) modes. Persisted, versioned onboarding state.
- **Hardware-aware model catalog.** Recommended models now carry context window, structured capabilities (chat/coding/reasoning/tool-calling/vision), and status (recommended/experimental/legacy/incompatible). `esh model recommended --for-this-mac` and `--profile coding|reasoning|fast|best|low-memory`; new `esh model info <model>` and `esh model compatibility <model>`.
- **First-class local models.** `esh model import <path>` registers a local MLX directory or GGUF file with no re-download (copy or `--move`); `esh model scan [<dir>] [--clean]` discovers models already on storage and cleans orphaned partial downloads.
- **Richer diagnostics.** `esh doctor --json` emits a stable machine-readable health report (status, host, storage, engines, models); human output now includes storage availability, host, and incomplete-install detection.

### Changed
- Aligned swift-syntax with the Swift 6.3 toolchain (600.0.1 → 603.0.2).
- TTS voice models and generated audio now write under the configured assets root (e.g. `~/.esh/audio`) instead of the current working directory.
- Config gains an explicit schema version; the unused `model_dir` knob is deprecated in favor of `esh storage`. Path expansion (`~`, `$HOME`, relative, absolute) is standardized.
- `esh doctor` remains a non-failing diagnostic: it reports `degraded` (e.g. when only one engine is available) but exits 0; pass `--strict` to make a non-`ok` status exit non-zero for health-gating.

## [0.1.41] - 2026-05-12

### Fixed
- Packaged MLX and TurboQuant runtimes now resolve their bundled Python helper paths from the installed release layout instead of falling back to compile-time source checkout paths.

## [0.1.40] - 2026-05-07

### Added
- Added MLX 0.5 generation controls for thinking-mode chat templates and KV-cache quantization across OpenAI-compatible requests, external inference, the CLI, and the MLX bridge.
- Advertised MLX thinking-mode and KV-cache quantization capabilities while explicitly marking `json_schema` response format constrained decoding as unavailable.

## [0.1.39] - 2026-05-07

### Changed
- Updated the MLX VLM bridge dependency contract to `mlx-vlm` 0.5.0 with compatible `mlx` and `mlx-lm` minimum versions.
- Bumped MLX cache/runtime metadata to `mlx-vlm-0.5.0+mlx-lm-bridge-v3` so older 0.4.3 prompt-cache artifacts remain version-isolated.

## [0.1.38] - 2026-04-30

### Added
- Backend capability reports for MLX and llama.cpp runtime feature detection.
- Normalized prompt cache keys on new cache manifests for future cache lookup and reuse policy.

## [0.1.37] - 2026-04-30

### Added
- Runtime orchestration commands: `esh config`, `esh engines list`, `esh engines doctor`, and `esh validate`.
- Passive llama.cpp and MLX readiness checks with local model validation for GGUF files and MLX model directories.
- Optional engine tracking for llamafile, Ollama, Transformers, and llama.cpp server adapters.

### Changed
- llama.cpp runtime lookup no longer attempts automatic Homebrew installation; it now reports the missing dependency and suggested fix.

## [0.1.35] - 2026-04-29

### Added
- Runtime generation controls for chat, `esh infer`, OpenAI-compatible requests, Anthropic-compatible requests, MLX, and GGUF backends.
- Chat commands for inspecting and changing generation options while a session is running.

### Fixed
- OpenAI and Anthropic local compatibility now tolerates non-text content parts instead of rejecting requests that include image or unsupported parts.
- Packaged smoke tests now skip MLX doctor failures only when the current macOS session cannot expose a Metal GPU.

## [0.1.33] - 2026-04-25

### Added
- OpenAI-compatible audio speech generation at `POST /v1/audio/speech`, including direct WAV responses for terminal-driven agents and the TUI-hosted local API.

### Fixed
- Debug SwiftPM builds no longer emit stale clang module-cache warnings.

## [0.1.31] - 2026-04-25

### Fixed
- Xcode local model provider compatibility by keeping `/v1/models` text-only and adding local-provider probes.

### Added
- OpenAI-compatible server now exposes `/v1/tools`, `/api/tags`, root health, query-safe routing, CORS headers, and port `11435` defaults for Xcode.

## [0.1.30] - 2026-04-25

### Fixed
- SwiftPM build no longer reports unhandled `mlx-audio-swift` README files.

## [0.1.29] - 2026-04-25

### Added
- TUI launcher now exposes an OpenAI server toggle with live on/off state.
- Chat TUI now shows OpenAI server state in the header and supports `/serve toggle|start|stop|status`.

## [0.1.28] - 2026-04-25

### Added
- `esh serve` exposes an OpenAI-compatible local HTTP server for model listing, chat completions, and responses.
- OpenAI-compatible model discovery now includes MLX TTS audio models plus `/v1/audio/models` voice/language metadata for external agents.

## [0.1.27] - 2026-04-24

### Fixed
- MLX chat cache export now handles bfloat16 prompt-cache tensors without failing generation.

## [0.1.26] - 2026-04-24

### Fixed
- macOS release packages now include the MLX Metal runtime library required by `esh audio speak`
- package smoke tests now fail when the bundled MLX Metal runtime library is missing

## [0.1.25] - 2026-04-24

### Added
- `esh audio` commands for listing MLX TTS models and generating WAV speech through TTSMLX
- an interactive Audio launcher entry for choosing a TTS model, voice, language, profile, and output path
- model task, modality, and capability metadata, including `esh model list --task` and `--capability` filters

### Changed
- model install preflight can proceed past unsupported runtime verdicts when `--force` is used
- generated `.esh` model and audio cache data is ignored by Git

## [0.1.24] - 2026-04-24

### Added
- expanded recommended model presets with additional Qwen, DeepSeek, Phi, Gemma, and GGUF options
- catalog coverage for the new recommended model aliases and backend-specific ordering

## [0.1.23] - 2026-04-24

### Added
- optional multi-model routing configuration with router, main, coding, embedding, and fallback model roles
- `esh routing` commands for status, enable/disable, role assignment, mode selection, and local routing tests
- routed `esh infer` and `esh chat --routing` execution with deterministic router JSON validation
- safe workspace-bounded `read_file` tool handling for routed filesystem requests

### Changed
- routed inference falls back to the main model when the router is unavailable, emits invalid JSON, has low confidence, or proposes an invalid tool call
- `parallel` routing mode is accepted as configuration and currently runs through the sequential fallback path

## [0.1.22] - 2026-04-11

### Added
- bounded autonomous agent mode can now create files, edit line ranges, and run explicit build/test verification steps
- agent runs now support resumption with `esh agent continue --run <id> --model <id-or-repo>` using compact continuation memory from persisted run state
- terminal chat now supports transcript scrolling for long responses with line, page, and jump navigation

### Changed
- agent final answers are now gated on successful verification after code edits, with repair-and-retry behavior after failed verification
- run state now records agent task lifecycle and per-step trace events for clearer status inspection and continuation

## [0.1.21] - 2026-04-04

### Changed
- no-model onboarding now supports switching between MLX and GGUF starter presets
- no-model onboarding and recommended presets now offer direct full-catalog search from the picker
- launcher search copy now reflects MLX and GGUF model discovery instead of MLX-only wording

## [0.1.20] - 2026-04-04

### Added
- arrow-key model disambiguation pickers for install, open, and check flows after search returns multiple matches

### Changed
- the shared model chooser now makes `Esc` cancellation explicit alongside `Enter` selection

## [0.1.19] - 2026-04-04

### Added
- backend switching between MLX and GGUF in the recommended-models picker
- a terminal-native interactive text prompt for launcher queries so search/install prompts no longer depend on `readLine()` after raw-key menus

### Changed
- model search results now install on `Enter` and open on `o`
- opening a model page from search, recommended presets, starter presets, chat model selection, or installed models now keeps you in the current picker instead of dropping you back to the launcher

## [0.1.18] - 2026-04-04

### Added
- `esh model check` with pre-download compatibility and fit estimates, JSON output, and conservative host-memory heuristics
- initial GGUF support through llama.cpp, including backend routing, support checks, and explicit `--variant` handling for GGUF quant variants
- GGUF-aware metadata inference and tests for format detection, quantization mapping, variant selection, and stable checker output

### Changed
- Hugging Face remote search now surfaces broader supported model results instead of forcing the old MLX-only app filter
- model install can now prompt for GGUF variants when a repo exposes multiple candidate files
- launcher and startup banner UI now size correctly for live counts and search/install flows remain usable from the interactive menu

## [0.1.5] - 2026-04-03

### Added
- colorful startup banner with live model/session/cache counts in the launcher
- model capability badges such as `chat`, `code`, `reason`, `vision`, and `long` in model pickers
- reasoning-aware chat formatting for models that emit explicit `<think>...</think>` blocks

### Changed
- launcher and model lists now use interactive highlighted pickers with arrow-key navigation
- pressing Enter on `Chat` now opens chat immediately, while `n` opens the named-session flow
- launcher descriptions now render inline on the right for a tighter command-palette layout

## [0.1.4] - 2026-04-03

### Added
- `esh model open` for opening a model page from an alias, installed id, repo id, or search term
- interactive highlighted pickers for the launcher menu and model selection flows

### Changed
- Hugging Face model search now uses the strict `apps=mlx-lm` filter
- model search and model lists now support opening and installing directly from the selected row
- launcher list descriptions now render inline on the right for a more compact layout

## [0.1.3] - 2026-04-03

### Added
- install-by-search now shows a numbered model chooser before any download starts
- install preflight now checks unified memory, available memory, and free disk space before downloading

### Changed
- stale partial downloads that trigger HTTP 416 now restart that file from zero automatically

## [0.1.2] - 2026-04-03

### Added
- `esh model recommended` with built-in stable MLX presets for fast first-time setup
- alias-based model install, for example `esh model install fast-chat`

### Changed
- model search output now uses compact fixed-width columns with source, state, model, kind, size, downloads, and date

## [0.1.1] - 2026-04-03

### Added
- `esh model search <query>` across local installs and Hugging Face
- a shared model catalog layer for local and remote discovery
- default launcher menu support for model search

## [0.1.0] - 2026-04-03

### Added
- local MLX-backed chat for Apple Silicon
- model install/list/inspect/remove
- saved sessions and in-chat session switching
- raw and TurboQuant cache build/load/inspect flow
- self-contained dev and release launchers
