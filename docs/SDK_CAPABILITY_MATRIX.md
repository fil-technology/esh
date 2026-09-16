# esh SDK — Authoritative Capability Audit (v2.4 feature-complete milestone)

Source of truth: the actual code on branch `g1-multimodal-facade` (base `v2.4.0-rc.7`), audited 2026-09-16.
This supersedes any status claim in older docs. "Public SDK exposure" = reachable by a consumer app that
links only the published SwiftPM products via `EshRuntime.makeDefault()` / `execute` / `stream` — NOT the
esh CLI's internal assembly.

## Legend
- **Exposure**: ✅ public facade · ⚙️ exists in esh but only in the CLI/macOS internal assembly (not SDK) · ❌ not in esh
- **Native**: in-process, no Python · **Compat**: esh-owned Python/MLX bridge (macOS dev/CLI today)

## Text
| Capability | Impl today | Exposure | iOS | macOS | Native? | Model/runtime | Stream | Cancel | Result | Tests | Remaining |
|---|---|---|---|---|---|---|---|---|---|---|---|
| chat / completion (`language.generate`) | Apple FM + GGUF (portable); MLX (macOS) | ✅ | ✅ FM/GGUF | ✅ +MLX | native | Apple FM / GGUF / MLX | ✅ | ✅ | text | ✅ | MLX text not in portable product (macOS only) |
| structured output | facade resolver (rc.7 §5) | ✅ | ✅ | ✅ | native | — | ✅ | ✅ | text/json | ✅ | native constrained decoding per-backend depth |
| reasoning events (`.reasoningDelta`) | ThinkingParser split (rc.7 §5) | ✅ | ✅ | ✅ | native | — | ✅ | ✅ | text+reasoning | ✅ | — |
| tool-call events (`.toolCall`) | accepted; honestly rejected (rc.7 §5) | ✅ | ✅ | ✅ | native | — | ✅ | ✅ | resolution | ✅ | no native local tool-calling backend yet |
| embeddings (`language.embed`) | llama-server (bundled) | ⚙️ | — | ⚙️ | compat (native GGUF possible) | GGUF embed | — | — | embedding | — | expose; native via EshLlamaCpp embeddings |
| rerank (`language.rerank`) | llama-server | ⚙️ | — | ⚙️ | compat | GGUF rerank | — | — | ranked | — | expose or defer |

## Vision / image understanding
| Capability | Impl today | Exposure | iOS | macOS | Native? | Remaining |
|---|---|---|---|---|---|---|
| OCR (`image.ocr`) | AppleVisionOCRProvider | ✅ | ✅ | ✅ | native (Vision) | done |
| image understanding (`image.understand`) | mlx-vlm (Python) | ⚙️ | ❌ | ⚙️ | compat → **native target: MLX-Swift MLXVLM** | build native VLM provider (§14) |
| video understanding (`video.understand`) | AVFoundation + mlx-vlm | ⚙️ | ❌ | ⚙️ | compat (AVFoundation native + VLM) | expose; native VLM per-frame |

## Image
| Capability | Impl today | Exposure | iOS | macOS | Native? | Remaining |
|---|---|---|---|---|---|---|
| segmentation / bg-removal (`image.segment`) | rembg (Python) | ⚙️ | ❌ | ⚙️ | **native target: Vision foreground mask** | **build native (quick win §10)** |
| upscale (`image.upscale`) | Real-ESRGAN ONNX (Python) | ⚙️ | ❌ | ⚙️ | native target: Core ML / MetalFX | build native (§10) |
| generation (`image.generate`) | mflux FLUX/Z-Image (Python) | ⚙️ | ❌ | ⚙️ | native target: Core ML SD / MLX-Swift SD | build native + model hosting (§11/§12) |
| editing (`image.edit`) | Qwen-Image-Edit / FLUX Kontext (Python) | ⚙️ | ❌ | ⚙️ | Core Image (deterministic) native; instruct-edit → compat | native deterministic + macOS compat instruct-edit (§15) |

## Speech
| Capability | Impl today | Exposure | iOS | macOS | Native? | Remaining |
|---|---|---|---|---|---|---|
| STT (`audio.transcribe`) | AppleSpeechTranscribeProvider (SFSpeechRecognizer) | ✅ | ✅ | ✅ | native | device validation (mic/permission) |
| TTS / voice (`audio.synthesizeSpeech`) | AppleSpeechSynthesizeProvider (AVSpeechSynthesizer) | ✅ | ✅ | ✅ | native | done (voice/speed via options) |
| diarization (`audio.diarize`) | sherpa-onnx (Python) | ⚙️ | ❌ | ⚙️ | compat | expose via macOS compat or defer (§19) |

## Audio / Music
| Capability | Impl today | Exposure | iOS | macOS | Native? | Remaining |
|---|---|---|---|---|---|---|
| SFX generation (`audio.generate`) | AudioGen (Python) + deterministic DSP | ⚙️ | ❌ | ⚙️ | no mature native | expose via macOS compat; iOS unsupported (§17) |
| music generation (`music.generate`) | MusicGen (Python) | ⚙️ | ❌ | ⚙️ | no mature native | expose via macOS compat; iOS unsupported (§18) |

## Video
| Capability | Impl today | Exposure | Remaining |
|---|---|---|---|
| understanding (`video.understand`) | AVFoundation + mlx-vlm | ⚙️ | expose (macOS compat / native VLM) |
| generation (`video.generate`) | ❌ not in esh | ❌ | report `comingLater`/unsupported (§20) |
| editing (`video.edit`) | ❌ not in esh | ❌ | report `comingLater`/unsupported |

## Create (structured artifacts)
| Capability | Impl today | Exposure | iOS | macOS | Native? | Remaining |
|---|---|---|---|---|---|---|
| SVG (`vector.generate`) | TextToSVGProvider | ✅ | ✅ | ✅ | native (LLM+renderer) | done |
| Website (`webArtifact.generate`) | WebArtifactProvider | ✅ | ✅ | ✅ | native | done |
| Code/project (`project.generate`) | ProjectGenProvider | ✅ | ✅ | ✅ | native | done |

## Summary of gaps to close for feature-complete
1. **Native quick wins:** `image.segment` (Vision), `image.upscale` (Core ML/MetalFX), deterministic `image.edit` (Core Image). Portable, no Python.
2. **Native generators/understanding:** `image.generate` (Core ML SD / MLX-Swift) + model hosting; `image.understand` (MLX-Swift VLM). Opt-in products.
3. **esh-owned macOS compatibility runtime** (approved §6) for capabilities with no native path yet: `audio.generate`, `music.generate`, advanced instruct `image.edit`, `audio.diarize`, `video.understand`, `language.embed/rerank` — esh owns Python lifecycle; consumers never touch Python; iOS reports `unsupportedOnPlatform`.
4. **Discovery + Auto/Model-Fit** extended per capability; **artifact + event contracts** already exist (rc.6/7) — verify coverage for new modalities.
5. **Packaging:** introduce opt-in products only when a heavy dependency (MLX-Swift / Core ML models) actually requires it; Vision/Core Image providers stay in EshCore (zero-dep, like OCR).

## Not in esh (honest)
Video generation, video editing — do not exist; will report `comingLater`/`unsupportedOnPlatform`, not invented.
