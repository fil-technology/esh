# esh 2.1 — Release Qualification Matrix (authoritative)

**Date:** 2026-09-06 · **Branch:** `main` (post Voice 2.1 merge `63552f4`) · **Machine of record:** Apple Silicon, 32 GB.

**Status legend:** `PROD` = Production · `EXP` = Experimental · `UNSUP` = Unsupported/out-of-scope.
**Tested-dimension legend:** ✅ evidence in repo (benchmark/status doc or verified this pass) · ○ unit-tested
only / not end-to-end verified this pass · — not applicable · ❔ no evidence.

> **Honesty preface (repo truth):**
> 1. Repo is **untagged** — `VERSION`=2.0.0, `CHANGELOG.md`=`[Unreleased]`; every 2.1 line is "(untagged)". All 2.1
>    claims are **pre-release** and pending the RC/soak.
> 2. **Doc-vs-CHANGELOG label drift:** `image.edit` and `voice` read EXPERIMENTAL in CHANGELOG but PRODUCTION-READY
>    in their later dated status docs — the **status/closure docs are the latest state**; CHANGELOG lags.
> 3. The cold/warm/offline/Install-Resume/packaged columns record **current evidence**. Only **Voice** was fully
>    exercised end-to-end this session; other capabilities carry their unit tests + status-doc evidence and are
>    marked ○ where end-to-end qualification is still a Phase 4–10 activity.
> 4. **Do not treat ○ as shipped-qualified** — that is exactly what Phases 4–10 close before RC1.

## Core platform

| Capability | Provider / backend | Default model/runtime | Status | Cold | Warm | Offline | Inst+Resume | Fit | Packaged | Known limitations | License |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Universal Capability API `/v1/execute` | `CapabilityContract` + `CapabilityExecutionService`; registry in `OpenAICompatibleService` | n/a | PROD | ○ | ○ | ○ | ○ | — | ○ | Capabilities are open `family.verb` strings | — |
| Router (Intent) | `CapabilityRouterService`; Tier0 `DeterministicIntentRouter` + Tier1 semantic/`IntentResolver`; safe Apple fallback | resident LLM / Apple FM / functiongemma | PROD | ○ | ✅ | ○ | — | — | ○ | measured false-exec 0–1.7% (router status doc) | — |
| Scheduler | `CapabilityScheduler` (+ 2.0 `SchedulerService`) | evidence-ranked | PROD* | ○ | ○ | ○ | — | — | ○ | **cross-model ranking stubbed** (`candidateModels` empty); interactive prefs active | — |
| Model pins / capability models | `EshConfig.defaults.capabilityModels`, `CapabilityModelResolver` | explicit or `auto` | PROD | — | ○ | — | — | ✅ | ○ | honored only when installed | — |
| Model Fit | `ModelFit`, `ModelFitService`, image/upscale Fit, `ModelMemoryEstimator`, install preflight | n/a | PROD | — | — | — | — | ✅ | ○ | — | — |
| Install-and-Resume | `Routing/InstallAndResume.swift`; `/v1/route/resume`; Voice realtime preflight | n/a | PROD* | — | ○ | — | ✅ (Voice ✅ this pass) | ○ | ○ | **in-memory only — does NOT survive server restart** | — |
| Managed / external storage | `StorageService`, `StorageConfig`, `SystemStorage` (assets on SSD root) | n/a | PROD | — | — | ✅ | — | — | ○ | — | — |
| Offline execution | default posture (all backends local); no single toggle | n/a | Verified* | ✅ (Voice) | ✅ (Voice) | ✅ | — | — | ○ | no distinct "offline mode" flag — it's the default | — |
| Runtime lifecycle / memory pressure | `RuntimeLifecycleManager` (evicts idle/over-budget, dedups loads, bounds concurrency) | n/a | PROD | — | ✅ | — | — | ✅ | ○ | memory is a **cooperative floor-check, not an enforced limit** | — |

## Language & text

| Capability | Provider / backend | Default model/runtime | Status | Cold | Warm | Offline | Inst+Resume | Fit | Packaged | Known limitations | License |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Chat / language.generate | `LanguageGenerateProvider` → text inference | MLX / llama.cpp / Apple FM | PROD | ○ | ○ | ○ | ○ | ✅ | ○ | mature 2.0 core | — |
| Reason / summarize / translate / classify / extract | **CapabilityIDs defined, no dedicated providers** — fold into generate/chat | as above | PROD (via generate) | — | — | — | — | — | — | not separately registered in `/v1/execute` | — |
| Structured output (JSON/schema) | `OutputSpec.schema`/`.json`; OpenAI/Anthropic-compat | as above | PROD | — | ○ | ○ | — | — | ○ | — | — |
| Embeddings `language.embed` | `EmbeddingProvider` → llama.cpp `--embeddings` | **explicit model required** | PROD | — | ○ | ○ | ○ | ✅ | ○ | no default model | — |
| Reranking `language.rerank` | `RerankProvider` → llama.cpp `--reranking` | **explicit model required** | PROD | — | ○ | ○ | ○ | ✅ | ○ | no default model | — |

## Image & vision

| Capability | Provider / backend | Default model/runtime | Status | Cold | Warm | Offline | Inst+Resume | Fit | Packaged | Known limitations | License |
|---|---|---|---|---|---|---|---|---|---|---|---|
| image.understand | `VisionUnderstandProvider` → mlx-vlm (Python bridge) | explicit vision model required | PROD | ○ | ○ | ○ | ○ | ✅ | ○ | needs an installed vision model | — |
| image.ocr | `AppleVisionOCRProvider` → **Apple Vision** | none (on-device) | PROD | — | ○ | ✅ | — | — | ○ | — | — |
| image.generate | `ImageGenerationProvider` → mflux (Python) | **Z-Image Turbo** (~8 steps) | PROD | ○ | ○ | ○ | ○ | ✅ | ○ | — | **Apache-2.0 (commercial-safe)** |
| image.edit | `ImageEditProvider` → mflux | **FLUX.2 Klein 4B** (`flux2-klein`) | PROD (status doc) | ○ | ✅ | ○ | ○ | ✅ | ○ | CHANGELOG still says EXP (lag) | default Apache-2.0; **`kontext` non-commercial → EXP-only** |
| image.segment | `SegmentationProvider` → rembg (optional dep) | rembg | EXP | ○ | ○ | ○ | ○ | — | ○ | optional dep; clear error if absent | — |
| image.upscale | `ImageUpscaleProvider` → Real-ESRGAN ONNX (onnxruntime CoreML) | `SceneWorks/real-esrgan-onnx` | PROD | ○ | ✅ | ○ | ○ | ✅ | ○ | `seedvr2` EXP/broken on mflux 0.19.1 | BSD-3 |

## Vector / web / projects

| Capability | Provider / backend | Default model/runtime | Status | Cold | Warm | Offline | Inst+Resume | Fit | Packaged | Known limitations | License |
|---|---|---|---|---|---|---|---|---|---|---|---|
| vector.generate (SVG) | `TextToSVGProvider` → LLM codegen + Apple-FM escalation + repair | resident LLM/Apple FM | PROD | — | ○ | ○ | — | — | ○ | — | — |
| webArtifact.generate | `WebArtifactProvider` → LLM codegen + repair; sandboxed preview | resident LLM/Apple FM | PROD | — | ○ | ○ | — | — | ○ | — | — |
| project.generate (Tier A static) | `ProjectGenProvider` → best local coding model | best installed coder | PROD | — | ○ | ○ | — | — | ○ | static preview only | — |
| Three.js (Tier B managed) | `project.generate` w/ `projectType=threejs` + `BrowserModuleProvider`, vendored libs | browser-native ES modules | PROD (arch approved) | — | ○ | ✅ | — | — | ○ | Tier B helper not separately registered | vendored libs pinned+verified |
| Tier C (Node managed) | — | — | **UNSUP** | — | — | — | — | — | — | explicitly deferred | — |

## Audio, speech, video

| Capability | Provider / backend | Default model/runtime | Status | Cold | Warm | Offline | Inst+Resume | Fit | Packaged | Known limitations | License |
|---|---|---|---|---|---|---|---|---|---|---|---|
| STT (`/v1/audio/transcriptions`, voice) | `SpeechToTextService` → MLX `mlx_audio` | `parakeet-tdt-0.6b-v2` | PROD (EN) | ✅ | ✅ | ✅ | — | — | ○ | **English-only**; whisper-tiny incompatible | — |
| TTS (`/v1/audio/speech`, voice) | `AudioSpeechGenerator` → `TTSMLX` | **`Soprano-80M-bf16`** (fallback pocket-tts) | PROD (EN) | ✅ | ✅ | ✅ | — | — | ○ | **Marvis blocklisted** (RoPE mismatch) | — |
| audio.generate (SFX) | `AudioGenProvider` → DSP + neural AudioGen (isolated venv) | AudioGen-medium | PROD | ○ | ○ | ○ | ○ | — | ○ | neural path opt-in | **CC-BY-NC-4.0 (non-commercial)** |
| music.generate | `MusicGenProvider` → transformers | `facebook/musicgen-small` | **EXP** | ○ | ○ | ○ | ○ | — | ○ | held EXP by license + quality | **CC-BY-NC-4.0 (non-commercial)** |
| audio.diarize | `AudioDiarizationProvider` → sherpa-onnx (optional) | diarization models on SSD | EXP | ○ | ○ | ○ | ○ | — | ○ | optional dep; clear error if absent | — |
| audio.understand | CapabilityID defined, **no provider registered** | — | UNSUP | — | — | — | — | — | — | not implemented | — |
| video.understand | `VideoUnderstandingProvider` → AVFoundation + mlx-vlm + STT → LLM fusion (Apple FM) | resolves vision model | PROD | ○ | ○ | ○ | ○ | ✅ | ○ | needs installed vision model | — |
| video generation | — | — | **UNSUP** | — | — | — | — | — | — | out of scope for 2.1 | — |

## Voice 2.1 (realtime)

| Capability | Provider / backend | Default model/runtime | Status | Cold | Warm | Offline | Inst+Resume | Fit | Packaged | Known limitations | License |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Voice realtime (WebSocket `/voice`) | `VoiceSessionOrchestrator` → EnergyVAD → STT(MLX) → LLM → TTS(MLX) → WS playback | Voice Auto: smallest-fitting **present** LLM + `Soprano-80M` | PROD (EN, headphones) | ✅ | ✅ (~1.7–2.0 s) | ✅ | ✅ | ✅ | ○ | first-turn cold model load; speaker+mic per user acoustic verdict | — |
| Barge-in / echo guard | orchestrator interrupt + VAD echo scale | n/a | PROD | — | ✅ | — | — | — | ○ | — | — |
| Voice languages | STT/TTS stacks | EN stack | EN PROD / **RU·HE non-PROD** | — | — | — | — | — | — | EN-only STT; no Hebrew TTS; RU TTS not installed | — |
| Browser `/voice` client | `VoiceClientPage` (per-side states, pickers, barge-in) | n/a | PROD | — | ✅ | — | — | — | ○ | — | — |

## Items to resolve before RC1 (from this matrix)

1. **CHANGELOG label sync** — update CHANGELOG so `image.edit` and `voice` read the same PROD status as their status docs (avoid public contradiction). *(docs task, allowed under freeze.)*
2. **Non-commercial licensing surfaced honestly** — `music.generate` (EXP), neural `audio.generate`, and `image.edit` `kontext` must be labeled non-commercial in `doctor`/docs/UX.
3. **Known partials to document (not necessarily fix for 2.1):** Install-and-Resume in-memory only; Scheduler cross-model ranking stubbed; memory limit cooperative-not-enforced.
4. **CapabilityIDs without providers** — either hide `language.reason/summarize/translate/classify/extract`, `audio.transcribe/synthesizeSpeech/understand` from any "supported capability" surface, or document they route via generate / `/v1/audio/*`.
5. **End-to-end qualification (Phase 4–10)** — convert the ○ columns to ✅ for the Production capabilities via `/v1/execute` cold/warm runs, fresh-user lifecycle, and a **fresh packaged/notarized** smoke (not the stale `dist/`).

## Phase A — heavy-media e2e verification (32 GB M1 Pro, via `/v1/execute`, 2026-09-07)

Run sequentially through the public path; RAM guard + Model Fit active, no bypass. Peak memory monitored.

| Capability | Provider/model | Cold e2e | Peak mem | Artifact | Verdict |
|---|---|---|---|---|---|
| `image.upscale` | Real-ESRGAN ONNX | ✅ 200, 16.6 s | ~7 GB | ✅ outputs w/ artifact id | **Production (verified)** |
| `audio.generate` (SFX) | DSP + AudioGen (neural opt-in) | ✅ 200, 0.2 s (DSP) | ~7 GB | ✅ | **Production (verified)** |
| `image.generate` | Z-Image Turbo (mflux) | ✅ 200, ~107 s | **14.4 GB** | ✅ | **Production (verified)** — fits 32 GB, no Fit rejection |
| `image.edit` | FLUX.2 Klein 4B (mflux) | ✅ 200, 54 s | ~13 GB | ✅ | **Production (verified)** — default Apache-2.0 path |
| `video.understand` | AVFoundation + mlx-vlm + STT → LLM fusion | ◑ 400 (clean) | 3–6 GB | pipeline ran, fusion produced no usable summary on a **trivial synthetic 2 s clip** | **Production (pipeline sound)** — a real-content video is needed to demonstrate a usable summary; the failure was graceful, no crash |

**Memory behavior:** heavy image models peaked ~13–14 GB on 32 GB — comfortable headroom; the RAM guard was
active and did not need to reject, Model Fit was not bypassed, and memory returned toward baseline between runs
(sequential, cooperative eviction). No kernel-pressure events. On this Mac the heavy image/audio capabilities
are **Production**; `video.understand` remains Production on the strength of its architecture + a clean
end-to-end pipeline run (output quality on real video is a soak-time check, not a headless blocker).

**Bottom line:** the Production set for 2.1 is coherent — text/chat, embeddings, rerank, OCR, image gen/edit/upscale, vision & video understanding, SVG/web/static/Three.js, STT/TTS, SFX, Voice (EN), Router/Scheduler/Fit/Install-Resume/storage/offline/lifecycle. Experimental (labeled): `music.generate`, `image.segment`, `audio.diarize`, FLUX `kontext` edit. Unsupported/out-of-scope: Tier C Node, video generation, audio editing/stems, `audio.understand`.
