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
| instruct editing (`image.edit`) | Unsupported | **Experimental** | native (`.mlx`) | InstructPix2Pix / SD1.5 (CreativeML OpenRAIL-M) via `mlx-swift-image-edit` | content-preserving instruct edit; real-validated on M1 Pro (blue car→red / day→sunset / add snow preserve source). fp16 ~2 GB, token-free, sha256-pinned. Native wins over the compat path. Peak RSS ~7 GB (2 GB MLX cache cap). |
| instruct editing (`image.edit`, fallback) | Unsupported | Experimental | compat | mflux qwen-image-edit-2511 4-bit (Apache-2.0) | Python-bridge fallback where the native path is unavailable; not sandbox-viable. Weights (~27 GB) require external storage. |

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
