# esh 2.1 — User Guide

> Draft public documentation for esh 2.1. Accurate to `main` as of the Voice 2.1 merge. esh 2.1 is **not yet
> tagged** — commands that reference a released package apply once `v2.1.0` ships. Authoritative capability
> status: [`2_1_RELEASE_QUALIFICATION_MATRIX.md`](2_1_RELEASE_QUALIFICATION_MATRIX.md).

## What is esh?

esh runs AI **capabilities locally on your Mac** using the best compatible on-device model. You give it a
capability and constraints; esh decides how to execute it — which runtime (MLX, llama.cpp, Apple Foundation
Models), which model, and how to fit it in memory — and runs it **on-device**. No cloud inference; your inputs
stay on your machine.

Its guarantee: *"Give me a capability and constraints, and esh will determine how to execute it locally on this
Mac using the best compatible intelligence available."*

## Installation

**Requirements:** Apple Silicon Mac, macOS 14+. Some capabilities need extra runtimes (a Metal-capable GPU is
used automatically).

- **Homebrew (once 2.1 is released):** `brew install fil-technology/tap/esh` *(available at release)*.
- **From source (today):**
  ```bash
  git clone https://github.com/fil-technology/esh.git && cd esh
  swift build -c release --product esh
  .build/release/esh doctor
  ```
  `llama.cpp` (`llama-server`) and a Python env for MLX bridges are auto-detected; run `esh doctor` to see what
  is ready and what to install.

## Quick start

```bash
esh serve                     # starts the local server + Web UI + Voice
```
Then open:
- **Web chat / capabilities:** http://127.0.0.1:11435/web
- **Voice (realtime):** http://127.0.0.1:11435/voice
- The realtime Voice WebSocket is the companion port (serve port + 1, default `11436`).

Stop the server with **Ctrl+C** (not Ctrl+Z — that suspends it and keeps the port held). Starting a new server
detects a previous esh holding the port (including the Voice companion port) and offers to stop it.

## Web UI

`http://127.0.0.1:<port>/web` is the reference client over the local esh API: chat, capability execution
(image, SVG, web artifacts, projects), attachments, and artifact preview in an isolated sandbox.

## CLI

| Command | What it does |
|---|---|
| `esh serve [--host H] [--port N] [--api-key T]` | Local OpenAI-compatible + Universal API server, Web UI, Voice |
| `esh chat [name] [--model <id>]` | Terminal chat |
| `esh doctor [--json] [--strict]` | Diagnostics (hardware, storage, runtimes, models, Voice, offline readiness) |
| `esh model search\|install\|list\|remove\|fit\|check <...>` | Model lifecycle |
| `esh capabilities` | List capabilities esh can route/execute |
| `esh audio models` · `esh audio speak <text> [--model] [--voice] [--out]` | TTS |
| `esh storage show\|set <path>\|use-internal\|doctor` | Managed storage |
| `esh routing status\|test <prompt>` | Capability router |
| `esh update [check] [--json]` | Update state |

## Universal Capability API — `/v1/execute`

The canonical way to run any capability:
```bash
curl http://127.0.0.1:11435/v1/execute -H 'Content-Type: application/json' -d '{
  "capability": "language.generate",
  "inputs": [ { "payload": { "text": "Write a haiku about local AI." }, "role": "prompt" } ],
  "output":  { "modality": "text" },
  "options": { "values": {} }
}'
```
- `capability`: a `family.verb` id (e.g. `language.generate`, `image.generate`, `image.ocr`, `vector.generate`,
  `webArtifact.generate`, `project.generate`, `video.understand`, `audio.generate`).
- `inputs`: typed — `{payload:{text:…}}`, `{payload:{attachment:…}}` (image/doc/audio), or structured.
- `output`: `{modality:"text|image|audio|json|embedding", format?, schema?}`.
- `model` (optional): pin a specific installed model; omit for **Auto**.
- Stream events with `POST /v1/execute?stream=1` (Server-Sent Events).

Related: `POST /v1/route` (decide the capability from a message) and `POST /v1/route/resume` (Install-and-Resume).

## OpenAI-compatible API

Drop-in endpoints for existing clients: `POST /v1/chat/completions` (+ `stream`), `GET /v1/models`,
`POST /v1/audio/speech`, `POST /v1/audio/transcriptions`, `GET /v1/audio/models`, `POST /v1/responses`,
`GET /api/tags`. Point any OpenAI SDK at `http://127.0.0.1:11435/v1`.

## Auto (routing + model selection)

**Auto** means you don't pick the model. The **Router** decides the capability (deterministic first, then a
constrained semantic pass that abstains when unsure, with a safe Apple-Foundation-Models fallback), and the
**Scheduler** + **Model Fit** pick a compatible installed model that fits memory. Pin a model explicitly to
override Auto (per request `model`, or `esh` config `capabilityModels`).

## Models & Model Fit

```bash
esh model search "llama 3.2 3b"
esh model install mlx-community/Llama-3.2-3B-Instruct-4bit
esh model fit <model>        # will the whole stack fit this Mac's memory?
esh model list ; esh model remove <id>
```
**Model Fit** estimates whether a model (and its full runtime stack) fits your usable memory before you commit,
and classifies it (comfortable / fits / tight / unsupported).

## Install-and-Resume

When a capability needs a model you don't have, esh returns an **install requirement** (with the combined Fit)
instead of failing — you approve the install, it downloads to managed storage, and your original request
**resumes**. Voice does this at session start; the router does it via `/v1/route` → install card →
`/v1/route/resume`.
*Known limitation (2.1): pending resumes are held in memory and do not survive a server restart.*

## External / managed storage

Models and generated assets live under a **managed root** — put it on an external SSD to keep your internal
disk free:
```bash
esh storage set "/Volumes/YourSSD/esh-models"   # moves/points the managed root
esh storage doctor
```
Downloads go to the managed root, never unexpectedly to internal storage. If the volume is disconnected, esh
reports it clearly (`esh doctor` → storage: UNAVAILABLE) and you can reconnect or `esh storage use-internal`.

## Offline operation

esh runs on-device by design — no cloud inference. Once the models a capability needs are installed, that
capability works with **no network**. (esh only reaches the network to *download* models you ask for.)

## Voice

Open `http://127.0.0.1:11435/voice`, tap the orb, allow the microphone, and talk. esh runs VAD → speech-to-text
→ the language model → text-to-speech entirely on-device, streaming the reply back as you go. Pick the **Model**
and **Voice** from the top-right; tap the waveform to interrupt (barge-in). Headphones recommended.
- **English is the production Voice language.** Russian/Hebrew are **not** production in 2.1 (English-only STT
  and installed TTS; esh does not pretend to support them).
- First turn after choosing a model is slower (one-time load); subsequent turns are fast.

## Capability status matrix

See [`2_1_RELEASE_QUALIFICATION_MATRIX.md`](2_1_RELEASE_QUALIFICATION_MATRIX.md) for the authoritative
per-capability status (Production / Experimental / Unsupported), default models, and known limitations.

## Experimental features

Labeled Experimental in 2.1 (use with that expectation): `music.generate` and neural `audio.generate` (SFX)
and the `image.edit` `kontext` backend — these use **non-commercial (CC-BY-NC-4.0)** models; `image.segment`
(rembg) and `audio.diarize` (sherpa-onnx) require optional dependencies. **Out of scope for 2.1:** Tier C (Node)
managed projects, video generation, audio editing/stems/remix, `audio.understand`.

## Troubleshooting

- **`esh doctor`** is the first stop — it reports hardware, storage, runtimes (MLX / llama.cpp / Apple FM),
  installed models, Voice readiness, and offline readiness, with fixes.
- **Port already in use:** esh offers to stop a previous esh server (main + Voice ports) or pick a free one.
- **A capability says a model is missing:** install the recommended model, or pick one in the UI, then retry.
- **Voice won't connect:** open `/voice` on the **serve HTTP port** (the page derives the WebSocket as port+1);
  make sure `esh serve` printed the `Voice realtime (WebSocket) listening …` line.
- **A model crashes on load:** run `esh model remove <id>` for an incomplete install, or `esh model fit <id>`
  to check it fits this Mac.

## Updating & uninstalling

- **Update state:** `esh update check`.
- **Remove a model:** `esh model remove <id>` (frees managed-storage space).
- **Uninstall:** remove the esh binary (and the Homebrew formula when installed via brew); delete the managed
  storage root and `~/.esh` to remove all local state and models.

## Privacy & locality guarantees

- **Inference is on-device.** Your prompts, images, audio, and documents are processed locally; esh does not
  send them to a cloud model.
- **The only network use is model download** (from Hugging Face) when you install a model. After that, the
  capability runs offline.
- **Your data stays under your managed storage root and `~/.esh`.** Nothing is uploaded by esh.
