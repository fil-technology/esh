# esh SDK — Final Capability / Platform Matrix (v2.4.0-rc.8, Esh Studio dogfood RC)

Source of truth: the actual code at the rc.8 candidate on branch `g1-multimodal-facade`, closed 2026-09-16.
This supersedes every status claim in older docs. "In the SDK facade" = reachable by a consumer app that
links the published SwiftPM products and calls `EshRuntime` `execute` / `stream` / `capabilityAvailability`
— NOT the esh CLI's internal assembly.

## State vocabulary (one honest state per capability/platform)
- **Production** — shipping in the SDK facade and real-validated end-to-end on that platform.
- **Experimental** — shipping and wired in the facade, runs, but not held to the Production validation bar
  on this device yet (opt-in heavy path, first generation, non-commercial weights, or validation in progress).
- **Unsupported** — reports `.unsupportedOnPlatform` there (e.g. macOS-only compat engines on iOS).
- **Coming Later** — not shipping executable in this RC; discovery reports `.comingLater` (honest, not invented).

## Runtime classes
- **Native** — in-process Apple frameworks / MLX-Swift, no Python. Ships in `EshCore`/`EshRuntime` (portable)
  or the opt-in `EshVision` / `EshImageGen` products.
- **Compat** — esh-owned, esh-managed Python/MLX runtime in `EshMacCapabilities`. macOS-only; iOS reports
  `.unsupportedOnPlatform`. Consumers never touch Python — esh owns install/health/repair/process lifecycle.

---

## Text — `EshCore` + `EshRuntime` (portable)
| Capability | State (iOS) | State (macOS) | Class | Runtime | Notes |
|---|---|---|---|---|---|
| chat / completion (`language.generate`) | **Production** | **Production** | native | Apple FM + GGUF (iOS); +MLX (macOS) | MLX text is macOS-only; iOS uses Apple FM (iOS 26 gate) / GGUF |
| structured output | **Production** | **Production** | native | facade resolver | stream + cancel |
| reasoning events (`.reasoningDelta`) | **Production** | **Production** | native | ThinkingParser split | — |
| tool-call events (`.toolCall`) | **Production** | **Production** | native | facade | accepted and **honestly rejected** — no native local tool-calling backend exists yet; the event contract is real |
| embeddings (`language.embed`) | Coming Later | Coming Later | — | GGUF (CLI-internal) | exists in the CLI, **not** in the SDK facade |
| rerank (`language.rerank`) | Coming Later | Coming Later | — | GGUF (CLI-internal) | exists in the CLI, **not** in the SDK facade |

## Vision / understanding
| Capability | State (iOS) | State (macOS) | Class | Runtime | Notes |
|---|---|---|---|---|---|
| OCR (`image.ocr`) | **Production** | **Production** | native | Apple Vision | zero-dep, in `EshCore` |
| image understanding (`image.understand`) | **Experimental** | **Production** | native | MLX-Swift Qwen2-VL-2B-4bit (`EshVision`, opt-in) | real-validated on macOS (red-circle → correct description; 77.3 s first / 2.3 s reused; cancel 0.40 s). iOS builds but is not device-validated. Weights (~1.2 GB) require external storage. GPU tests build under xcodebuild. |
| video understanding (`video.understand`) | Unsupported | **Experimental** | compat | AVFoundation + VLM | pipeline runs; not yet real-validated on real-content video (prior trivial-clip run produced no usable summary) |

## Image
| Capability | State (iOS) | State (macOS) | Class | Runtime | Notes |
|---|---|---|---|---|---|
| segmentation / bg-removal (`image.segment`) | **Production** | **Production** | native | Apple Vision `VNGenerateForegroundInstanceMask` (iOS 17 / macOS 14) | in `EshCore`; discoverable + honest "no subject" failure; no model download |
| upscale (`image.upscale`) | **Production** | **Production** | native | MetalFX spatial scaler + Core Image Lanczos fallback (iOS 16 / macOS 13) | real-validated: 64×64 → 128×128 2×, MetalFX path (`apple-image-upscale.metalfx`), not the fallback |
| generation (`image.generate`) | Unsupported | **Experimental** | compat | mflux Z-Image-Turbo 4-bit (Apache-2.0) | real-validated on macOS (324 KB PNG on SSD, reused weights). Native MLX-Swift SD path = **Coming Later** (self-hosted SD 2.1-base weights checksum-pinned but pending a verified-provenance re-host). Weights require external storage. |
| edit — identity tier (`image.edit`, `model=mlx-photomaker-v1`) | Unsupported | **Experimental** | native (`.mlx`) | PhotoMaker v1 (SDXL, Apache-2.0/OpenCLIP, no InsightFace) via `mlx-swift-image-edit` | identity-preserving high-quality edit (e.g. "these people as a 3D animated character that still looks like them"). Style is an independent, swappable LoRA preset (default: Apache-2.0 goofyai/3d_render_style_xl @0.7, trigger "3d render" — no branded style). Native compact LoRA folding (no runtime Python). Peak ~12–13 GB (tiled VAE decode). esh-level dogfood: identity+style, cancel, warm reuse, external storage. |
| edit — lightweight tier (`image.edit`, `model=mlx-instruct-image-edit`, Auto default) | Unsupported | **Experimental** | native (`.mlx`) | InstructPix2Pix / SD1.5 (CreativeML OpenRAIL-M) | content-preserving instruct edit (recolor/relight/add-object); does NOT preserve facial identity. fp16 ~2 GB, token-free, sha256-pinned. Peak RSS ~7 GB. |
| instruct editing (`image.edit`, fallback) | Unsupported | Experimental | compat | mflux qwen-image-edit-2511 4-bit (Apache-2.0) | Python-bridge fallback where a native path is unavailable; not sandbox-viable. Weights (~27 GB) require external storage. |

## Speech
| Capability | State (iOS) | State (macOS) | Class | Runtime | Notes |
|---|---|---|---|---|---|
| STT (`audio.transcribe`) | **Production** | **Production** | native | `SFSpeechRecognizer` | mic/permission are the consumer app's responsibility |
| TTS (`audio.synthesizeSpeech`) | **Production** | **Production** | native | `AVSpeechSynthesizer` | voice/speed via options |
| diarization (`audio.diarize`) | Unsupported | **Experimental** | compat | sherpa-onnx | real-validated (JSON artifact on SSD). Models (~45 MB) require external storage. |

## Audio / Music
| Capability | State (iOS) | State (macOS) | Class | Runtime | Notes |
|---|---|---|---|---|---|
| music generation (`music.generate`) | Unsupported | **Experimental** | compat | MusicGen-small | real-validated (252 KB WAV on SSD). Weights **CC-BY-NC-4.0 — non-commercial** (dogfood only). External storage required. |
| SFX generation (`audio.generate`) | Unsupported | **Experimental** | compat | AudioGen-medium (mlx-audiocraft) | wired + discoverable; end-to-end run is **resource-gated on this device's current state** (see below). Weights **CC-BY-NC-4.0 — non-commercial**. External storage required. |

## Video (generation/editing)
| Capability | State | Notes |
|---|---|---|
| video generation (`video.generate`) | Coming Later | not in esh; discovery reports `.comingLater` |
| video editing (`video.edit`) | Coming Later | not in esh; discovery reports `.comingLater` |

## Create (structured artifacts) — `EshCore` + `EshRuntime` (portable)
| Capability | State (iOS) | State (macOS) | Class | Notes |
|---|---|---|---|---|
| SVG (`vector.generate`) | **Production** | **Production** | native | LLM + renderer |
| Website (`webArtifact.generate`) | **Production** | **Production** | native | single self-contained HTML |
| Code / project (`project.generate`) | **Production** | **Production** | native | multi-file project |

---

## SFX resource classification (recorded for closure)
The AudioGen SFX end-to-end run is **not** blocked by an implementation defect — the compat path is correct
(it was mid-run when the machine hit a kernel watchdog panic). The panic was **swap exhaustion**: AudioGen
(T5-large + audiogen-medium) running while the internal disk was ~97 % full. That is a genuine Model
Fit / resource limitation of this model on this device's current state, so it is **not an RC blocker**.

The SDK reports it honestly instead of running into swap:
- `CompatibilityCapabilityProvider` runs a disk-headroom preflight (required internal free =
  `max(8 GiB, 2× model footprint)`) and returns the typed `CompatibilityError.insufficientResources`,
  surfaced through discovery as `CapabilityAvailability.temporarilyUnavailable` (transient — freeing disk
  restores it). It does **not** hard-mark the device `.unsupportedOnDevice`.
- Operator-level defense: `scripts/compat-preflight.sh` gates any heavy compat run on internal + assets
  free-space headroom.
- The public SFX API is unchanged. On a machine with adequate free disk the same path runs; the durable
  gated integration test is `integrationSFXGeneratesAudioOnManagedRuntime` (`ESH_RUN_COMPAT_INTEGRATION=1`).

## Resource-aware Auto routing (rc.20)
When several providers implement the same capability at different cost (today: the `image.edit` identity vs
lightweight tiers), **Auto** (`ExecutionRequest.model == nil`) now picks the **highest-quality tier that
safely fits the live machine**, and falls back — or returns a typed transient gate — instead of running into
OOM / jetsam / swap exhaustion. This is a generic Scheduler / Model Fit layer, not PhotoMaker special-casing.

- **The app never sends model-specific facts.** esh owns each provider's `CapabilityResourceProfile`
  (estimated peak memory, download/install bytes, per-volume headroom, quality/latency). The caller only
  sends generic policy on `ExecutionConstraints`: `maxMemoryGB`, `reserveMemoryGB`, `allowDownload`,
  `offlineOnly`, `qualityPreference` (`auto`/`bestQuality`/`fastestReady`/`lowMemory`).
- **Storage is multiple resources.** The fit evaluator distinguishes the **system/runtime volume** (internal
  APFS, where swap lives) from the **assets/model volume** (often an external SSD) and from **staging**
  space. This is what makes "the weights fit the SSD, but the internal disk is nearly full" correctly
  *unsafe*: PhotoMaker declares an 18 GB system-volume/swap headroom, so on a machine with a full internal
  disk it is gated even when the SSD has hundreds of GB free. Real-machine dogfood on a 32 GB Mac with
  15.3 GB internal free / 616 GB SSD free: Auto → `mlx-instruct-image-edit` (PhotoMaker gated on swap
  headroom); the decision is emitted as an explainable `.status` line.
- **Explicit pins stay explicit.** A pinned `model` that does not fit returns
  `CapabilityError.resourceGated` (transient) — esh never silently substitutes a different provider.
- **Warm / anti-flapping.** A resident model reports warm state so re-use isn't falsely memory-gated; among
  equal-quality tiers the warm/installed one wins the tie-break, so routing doesn't oscillate.
- **Capability availability vs execution-time fit.** Discovery still reports whether the device/platform is
  *capable* (`.ready` / `.requiresDownload` / `.unsupportedOnPlatform`); the resource gate is the
  *execution-time* "supported but not safe right now" state, transient and surfaced as the typed error above.
- Providers that declare no resource profile keep the legacy native-first `.first` selection unchanged.

## Runtime resource + download-lifecycle APIs (rc.21)
Public facade over resource/lifecycle state esh already owns, so a consumer (Esh Studio) never fabricates
state or re-derives runtime knowledge. All additive; the existing `install(_:onProgress:)` is unchanged.

**Runtime resource state** (`EshRuntime`):
- `residentModels() -> [ResidentModel]` — heavy models esh is keeping resident, truthfully. Reports only
  providers that publish runtime state (the native image tiers today); each `ResidentModel` carries
  `residency` (`.warm`/`.active`/`.idle`), `estimatedPeakMemoryBytes` (declared), and `measuredMemoryBytes`
  (nil unless genuinely measured — never synthesized from an estimate). LLM/text residency is not tracked at
  this layer yet, so those are omitted rather than guessed.
- `resourcePressure() -> ResourcePressureSnapshot` — `totalMemoryBytes`, `availableMemoryBytes?`,
  `memoryCritical` (esh's judgment), `systemVolumeFreeBytes?` (internal/swap volume),
  `assetsVolumeFreeBytes?` (model volume).
- `unload(modelID:) async throws` — explicit per-model unload; an **active** model throws
  `UnloadError.modelActive` (never force-unloaded); unknown ids throw `.unknownModel`; already-unloaded is a
  no-op. `unloadIdleRuntimes() async` releases warm/idle-but-not-active models.

**Download lifecycle** (`EshRuntime`):
- `installStream(_:) -> AsyncThrowingStream<DownloadState, Error>` — rich progress (`bytesDownloaded`,
  `totalBytes`, `bytesPerSecond`, `etaSeconds`, `currentFile`, `phase`) instead of a bare `Double`.
- `installSession(_:) -> ModelDownloadHandle` — a stable handle (`id`, `events`, `pause()`, `resume()`,
  `cancel()`). **pause** retains the resumable partial; **resume** continues (not restart); **cancel**
  terminates cleanly and discards the partial. Removing an installed model (`remove`) stays separate.
- `DownloadState.Phase` gains `.paused`.

Not in scope (owned elsewhere): a multi-model download **queue** (the app sequences installs; esh owns each
one's lifecycle), and Automations (Ashex).

## Multi-output variants + timestamped transcript (rc.22)
Both additive over existing transport; single-output + text-only callers are byte-for-byte unchanged.

**A — Multi-output / variants.** `ExecutionRequest.outputCount: Int? = nil` (nil == 1) requests N candidate
variants from ONE execution over the existing plural transport (`.artifactProduced` per variant → `outputs:
[Artifact]`). Discovery: `CapabilityProviderDescriptor.supportsMultipleOutputs` + `maximumOutputCount`, read
via `EshRuntime.outputCapability(for:) -> (supportsMultiple, maxCount)` so consumers don't hardcode model
knowledge. esh clamps `outputCount` to the selected provider's `maximumOutputCount`. Variant lineage on
`ArtifactProvenance`: `batchID` (one execution), `variantIndex` (0…N-1), `seed` (the ACTUAL derived seed).
Seeds are deterministic via `VariantSeed.derive(base:index:)` — index 0 == base, so a single-output request
(or variant 0) reproduces the pre-rc.22 result exactly. First adopter: `image.generate` (`mlx-image-generate`,
`maximumOutputCount 4`) — per-variant seeded generation, so each artifact honestly records the seed that made
it (native SD batch shares one seed and can't). Other providers stay `maximumOutputCount 1`.

**B — Timestamped transcript.** New `ArtifactKind.transcript` + normalized public `Transcript` /
`TranscriptSegment` / `TranscriptWord` (Codable, reusable outside Studio). `audio.transcribe` now also emits a
`.transcript` artifact (`transcript.json`) built from the real `SFTranscription.segments` timing Apple already
produces (start = timestamp, end = timestamp + duration; `words = nil` — segment-only, never fabricated).
`ExecutionResult.text` + `.textDelta` streaming are unchanged (the transcript artifact is additive). A
plain-text-only backend yields a valid transcript with `segments: []`.

## External-storage requirement (shipping)
Every heavy-model capability requires a configured external assets volume (`~/.esh/storage.json` →
`assetsRoot`): native VLM, native/compat image.generate, compat image.edit, music, SFX, diarization,
video.understand. `caches/ models/ audio/ artifacts/ tmp/` all resolve onto that volume via
`PersistenceRoot.default()`. When the volume is missing these paths fail cleanly
(`StorageService.availability(root:)` → `unavailable`; test `storageUnavailableFailsCleanly`); zero-dep
native capabilities (OCR, segment, upscale, STT, TTS, Create, text) need no external storage. See
`docs/SDK_EXTERNAL_STORAGE_VALIDATION.md`.

## Shipping models — license / size / integrity
| Capability | Model | License | Approx size | Integrity |
|---|---|---|---|---|
| image.understand | `mlx-community/Qwen2-VL-2B-Instruct-4bit` | Apache-2.0 | ~1.2 GB | runtime loader |
| image.generate (compat) | `filipstrand/Z-Image-Turbo-mflux-4bit` | Apache-2.0 | ~5.5 GB | runtime loader |
| image.generate (native, Coming Later) | `stabilityai/stable-diffusion-2-1-base` (self-hosted mirror) | OpenRAIL-M | ~5 GB | **sha256-pinned** (unet/text_encoder/vae), verify-or-reject |
| image.edit (native) | `timbrooks/instruct-pix2pix` (fp16, upstream resolve) | CreativeML OpenRAIL-M | ~2 GB | **sha256-pinned** (unet/text_encoder/vae fp16), verify-or-reject; token-free |
| image.edit (compat, fallback) | `mflux-community/qwen-image-edit-2511-mflux-q4` | Apache-2.0 | ~27 GB | runtime loader |
| audio.diarize | sherpa-onnx segmentation + embedding | Apache-2.0 | ~45 MB | runtime loader |
| music.generate | `facebook/musicgen-small` | **CC-BY-NC-4.0** | ~2.2 GB | runtime loader |
| audio.generate (SFX) | `facebook/audiogen-medium` | **CC-BY-NC-4.0** | ~1.6 GB | runtime loader |

Non-commercial weights (MusicGen, AudioGen) are acceptable for Esh Studio dogfooding but must not ship in a
commercial product without a license change.

## Products
| Product | Platforms | Contents | External deps |
|---|---|---|---|
| `EshCore` | iOS 17 / macOS 14 | contracts, routing, Model Fit, persistence, native OCR/segment/upscale/Create | none |
| `EshRuntime` | iOS 17 / macOS 14 | the public facade (`execute`/`stream`/discovery), Apple FM/GGUF text, speech | none |
| `EshMacCapabilities` | macOS 14 (inert on iOS) | compat engines: music, SFX, image.generate, image.edit, diarization | none (EshCore/EshRuntime only) |
| `EshVision` (opt-in) | iOS 17 / macOS 14 | native VLM (image.understand) | mlx-swift-examples, swift-transformers, mlx-swift |
| `EshImageGen` (opt-in) | macOS 14 | native MLX-Swift SD (image.generate, Coming Later) | mlx-swift-examples, swift-transformers, mlx-swift |
| `EshLlamaCpp` (opt-in, when binary present) | iOS/macOS | embedded GGUF backend | prebuilt `esh_llama.xcframework` |

## Hugging Face model source (rc.23, HF1–HF9)
A first-class Hugging Face source, built on the existing model architecture (no second downloader, catalog,
or storage system). One authed repo fetch drives resolve + access + candidates; downloads reuse
`DownloadCoordinator` (now Authorization-threaded) and record credential-free provenance.

**Public API (`EshRuntime`, via `import EshRuntime`):**
| Method | Purpose |
|---|---|
| `parseHuggingFaceReference(_:) -> ModelSource?` | Parse `owner/repo`, a huggingface.co URL (`/tree`,`/blob`,`/resolve`), or `owner/repo@rev` (pure). |
| `huggingFaceAccountState() async -> HFAccountState` | `disconnected` / `connected(username:)` / `tokenInvalid` (validates via `whoami`). |
| `connectHuggingFace(token:) async throws -> String?` | Validate + store token in the **Keychain**; returns username. |
| `disconnectHuggingFace()` | Delete the stored token (sign out). |
| `huggingFaceAccess(_:) async throws -> ModelAccessStatus` | `publicAccess` / `authenticationRequired` / `gatedTermsRequired(actionURL:)` / `accessDenied` / `privateAuthorized` / `notFound`. |
| `resolveHuggingFace(_:) / (reference:) async throws -> ModelSourceRecord` | Metadata + access + license + compatibility + gated flag. |
| `huggingFaceArtifactCandidates(_:) async throws -> [ModelArtifactCandidate]` | Installable artifacts (GGUF quants / MLX layout), each with its own Model Fit; exactly one `isRecommended`. |
| `recommendHuggingFaceArtifact(from:) -> [ModelArtifactCandidate]` | Re-apply esh's recommendation (pure). |
| `searchHuggingFace(query:limit:) async throws -> [ModelSearchResult]` | Search (account's private/gated repos included when connected). |
| `installHuggingFaceSession(_:candidate:suggestedID:) async throws -> ModelDownloadHandle` | Controllable install (rich `events` stream + pause/resume/cancel). |
| `installHuggingFaceArtifact(_:candidate:suggestedID:onProgress:) async throws -> ModelInstall` | One-shot install (awaits completion). |
| `configureHuggingFace(credentials:http:)` | Optional DI (tests/hosts); production defaults to Keychain + `URLSession`. |

**Domain types (`EshCore`):** `HuggingFaceReference`, `HFAccountState`, `ModelAccessStatus`,
`SourceCompatibility`, `HFLicenseInfo`, `ModelArtifactCandidate`, `ModelSourceRecord`, `HuggingFaceError`
(typed, UX-safe), `HFCredentialStore` (+ `KeychainHFCredentialStore` / `InMemoryHFCredentialStore`),
`HuggingFaceInstallProvenance`.

**Compatibility verdict** is truthful: a raw HF resolve is at most `.compatible` — never `.verified`
(reserved for the curated catalog); unknown format → `.unknown`, no supported backend → `.unsupported`,
adapter/LoRA → `.experimental`.

**Model Fit + recommendation** use real per-file sizes (`?blobs=true`; LFS weights via `lfs.size`). The
recommendation is the heaviest artifact that fits comfortably/fits; when fit is unknown (no parameter hint)
it conservatively picks the lightest non-unsupported artifact.

**Provenance (HF6, credential-free)** recorded on `ModelInstall.huggingFace`: `repoID`, `revision` (commit
SHA), `files`, `format`, `quantization`, `licenseIdentifier`, `gated`, `isPrivate` (+ `sizeBytes`,
`installedAt`, backend on the install itself). No token is ever written to provenance, manifests, logs, or
`UserDefaults`.

**Storage:** HF installs honor the configured external assets root via `PersistenceRoot.default()` and fail
cleanly (never silently fall back to internal disk) when the volume/marker is missing.

**Security notes:** the token lives **only** in the Keychain (`technology.fil.esh.huggingface` /
`hf-token`, `kSecAttrAccessibleAfterFirstUnlock`); the public surface exposes account *state*, never the raw
token. The token is threaded into the download `Authorization` header, the metadata/search/whoami requests,
and `HubApi(hfToken:)` for native VLM/image weight fetches. Error strings pass through `HFTokenRedaction`.
No license auto-acceptance and no browser-HTML scraping; gated terms are surfaced as an `actionURL` for the
user to open on huggingface.co. "Commercial-safe" is never inferred — only the raw license identifier is
reported.

**Known limitations:** for an anonymous caller HF returns `401` for both private and non-existent repos, so
an unauthenticated resolve of a missing/private repo surfaces `authenticationRequired` (HF cannot
distinguish them without a token). OAuth is deferred (token + Keychain is the v1 auth). Model uploads /
training / conversion are out of scope.
