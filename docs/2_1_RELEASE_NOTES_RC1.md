# esh 2.1.0-rc.1 — Release Notes (Release Candidate)

**esh 2.1** turns your Mac into a local AI runtime: give it a capability and constraints, and esh picks the
best compatible on-device model and runs it — **on-device, private, offline-capable**. This is a **release
candidate** for soak testing; not the stable release.

## Headline: server-owned realtime Voice

- **Voice 2.1** — talk to esh in the browser at `/voice`: on-device VAD → speech-to-text → language model →
  text-to-speech, streamed over a WebSocket with barge-in. Live per-turn state, on-screen model/voice pickers.
  **English is production** (headphones); Russian/Hebrew are not production in 2.1.

## What's production in 2.1

Text / chat / reasoning / summarize / translate / classify / extract · structured output · **embeddings** ·
**reranking** · **image understanding** · **OCR** (Apple Vision) · **image generation** (Z-Image Turbo) ·
**image editing** (FLUX.2 Klein 4B) · **image upscale** (Real-ESRGAN) · **SVG / vector** · **web artifacts** ·
**static projects** & **Three.js** (managed, browser-native) · **STT** · **TTS** · **SFX** (`audio.generate`) ·
**video understanding** · **Voice (English)** · Universal Capability API (`/v1/execute`) · **Auto** routing +
Scheduler · **Model Fit** · **Install-and-Resume** · managed / **external SSD** storage · **offline** execution ·
runtime lifecycle / memory-aware residency.

**`audio.generate` is Production** — both the deterministic DSP path and the neural **AudioGen** SFX path passed
the listening gate. Its neural model (**AudioGen-medium**) is **CC-BY-NC-4.0 (non-commercial)** and is clearly
disclosed in `doctor`/docs; this is a licensing disclosure, not an experimental classification.

## Experimental (labeled — use with that expectation)

- `music.generate` (MusicGen) — **non-commercial (CC-BY-NC-4.0)**, limited quality evaluation.
- `image.edit` `kontext` backend (FLUX.1 Kontext) — **non-commercial**; the default edit path (FLUX.2 Klein) is
  Apache-2.0.
- `image.segment` (rembg) and `audio.diarize` (sherpa-onnx) — require optional dependencies.

## Not in 2.1 (out of scope)

Tier C (Node) managed projects · video generation · audio editing / stems / remix · `audio.understand`.

## Install

- **Homebrew:** `brew install fil-technology/tap/esh` (published with this release).
- **From source:** `swift build -c release --product esh`.

## Get started

```bash
esh serve
```
Then open the Web UI at `http://127.0.0.1:11435/web`, Voice at `http://127.0.0.1:11435/voice`, or point any
OpenAI SDK at `http://127.0.0.1:11435/v1`. Run `esh doctor` to see hardware, runtimes, models, and offline
readiness. Full guide: `docs/2_1_PUBLIC_GUIDE.md`; capability status: `docs/2_1_RELEASE_QUALIFICATION_MATRIX.md`.

## Known limitations (honest)

- **Install-and-Resume** pending resumes are held in memory and do **not** survive a server restart.
- **Scheduler** cross-model ranking is not yet active (interactive/config model preference is).
- **Memory** protection is a cooperative floor-check, not a hard enforced limit.
- **Voice languages:** English only for production; RU/HE are non-production (English-only STT; no Hebrew TTS).
- Heavy image models require sufficient memory; **Model Fit** will decline a model that does not fit this Mac
  rather than risk it — that is by design.

## Privacy & locality

Inference runs on-device; your prompts, images, audio, and documents are processed locally. The only network
use is downloading models you install. Data stays under your managed storage root and `~/.esh`.

---
*Release candidate — please report issues found during soak so they can be fixed before `v2.1.0` stable.*
