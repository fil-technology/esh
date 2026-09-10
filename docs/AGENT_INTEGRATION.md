# esh Agent Integration — Capabilities & Engines

How an external agent or client (e.g. Ashex) drives esh's on-device generation — images, audio, music,
and the other typed capabilities — through the stable HTTP API. This is the same contract the esh web client
uses. **The agent is a thin client: it triggers and tracks; esh owns routing, model lifecycle, engine
installation, memory safety, and storage.**

> Golden rule: **never run `pip`, build a venv, or invoke `mflux`/`mlx`/`mflux-generate` (or any Python CLI)
> directly.** A RAM guard sits in front of those; bypassing it has caused kernel panics. Everything goes
> through the HTTP API below.

Base URL: `http://127.0.0.1:11435` (loopback only by default).

---

## 1. Two ways to invoke a capability

**A. Natural language → `POST /v1/route`**
```json
{ "message": "generate an image of a red apple", "attachments": [], "conversationID": "c1" }
```
Returns a `RouteDecision`:
```json
{ "action": "chat | ready | installRequired | clarify | unsupported",
  "capability": "image.generate",
  "request": { … ExecutionRequest … },
  "installRequirement": { "componentName": "...", "approxSizeMB": 120,
                          "installKind": "engine | model | asset | adapter", "engineId": "image", "fit": { … } },
  "pendingId": "…", "reason": "…", "alternatives": [] }
```

**B. Direct** — when you already know the capability, skip routing and `POST /v1/execute` with a typed
`ExecutionRequest` (the same object `route` returns in `request`).

## 2. Handle every RouteDecision action (not just `ready`)

| action | do |
|---|---|
| `chat` | ordinary LLM turn, no capability |
| `ready` | run `request` via `POST /v1/execute?stream=1` (SSE) |
| `installRequired` | a component is missing — install it, then resume (see §4) |
| `clarify` | ask the user; offer `alternatives` |
| `unsupported` | say esh can't do this here |

## 3. Execute (streaming)

`POST /v1/execute?stream=1` streams newline-delimited JSON events:
`status`, `delta`, `reasoning`, `plan`, `artifact`, `preview`, `done`, `error`. Typed outputs (image / audio /
svg / webProject) arrive on `artifact`/`done`. Cancel by aborting the HTTP request.

A run can also fail with an `error` event carrying `"…not enough free memory…"` — treat that as a calm,
retryable condition (esh already reclaimed what it could), not a crash.

## 4. Install-and-resume — the agent never runs pip

When `action` is `installRequired`, install the named component, then **resume the original request** (the user
never re-types it):

1. **`installKind: "engine"`** → an optional generative runtime (see §5). Install:
   `POST /v1/engines/install {"id": "<engineId>"}`, poll `GET /v1/engines/install?id=<engineId>` until
   `phase` is `installed` (or `failed`).
2. **`installKind: "model" | "asset"`** → `POST /v1/models/install {"id": "<repo>"}`, poll
   `GET /v1/models/install?id=<repo>`.
3. Then **resume**: `POST /v1/route/resume {"pendingId": "<pendingId>"}` → a fresh `RouteDecision`.
   It may return another `installRequired` (e.g. the engine is now installed but the model weights are still
   missing) — install that too and resume again — or `ready`, which you execute.

A heavy capability can therefore take up to two install steps: **engine, then model weights.** Both are
esh-owned and tracked; the agent only triggers and polls.

## 5. Generative engines (installable, on-demand)

Heavy runtimes are **optional engines** kept out of the base install so a fresh esh stays small. Each engine's
Python deps and model weights are large and install on demand to **managed storage** (internal by default, the
external SSD when the user has set one — see §7). esh owns install/probe/remove.

`GET /v1/engines` → `{ "engines": [ { id, displayName, summary, installed, venvPath, approxSizeMB,
capabilities, commercialSafe, licenseNote, installKind } ] }`. Use it to show state and to know what needs
installing before offering a capability.

| engine id | powers | notes |
|---|---|---|
| `image` | `image.generate`, `image.edit` | mflux; default backends Apache-2.0 (commercial-safe); FLUX kontext edit is non-commercial |
| `sound-fx` | `audio.generate` | AudioGen; **CC-BY-NC** (non-commercial) |
| `music` | `music.generate` | MusicGen (torch); **CC-BY-NC** |
| `upscale` | `image.upscale` | Real-ESRGAN (onnxruntime) |
| `remove-bg` | `image.segment` | rembg |
| `diarize` | `audio.diarize` | sherpa-onnx |

- `POST /v1/engines/install {id}` / `GET /v1/engines/install?id=` (phases: `resolving`, `creating-env`,
  `installing`, `verifying`, `installed`, `failed`, `cancelled`) / `POST /v1/engines/install/cancel {id}`.
- `POST /v1/engines/remove {id}`.
- Surface `commercialSafe: false` + `licenseNote` to the user before installing a non-commercial engine.

## 6. Out-of-the-box vs needs-setup (fresh install)

| works out of the box | needs an engine install first |
|---|---|
| Chat (Apple Intelligence when present), Speech (TTS via `POST /v1/audio/speech`), Transcribe (STT via `POST /v1/audio/transcriptions`) | Imagine (`image`), Sound FX (`sound-fx`), Music (`music`), upscale/remove-bg/diarize |

Discover availability at runtime from `GET /v1/engines` and `GET /v1/engine` (a full health report) rather than
hardcoding. Degrade honestly: if an engine isn't installed, offer to install it (or say so) — never dump a raw
Python error to the user.

## 7. Storage — the user's single choice, honored everywhere

esh keeps **state** internal (`~/.esh`) and **assets relocatable**. Assets — model weights, caches, and now
engine venvs — live under the user's configured assets root: **internal by default**, external SSD only when
they opt in (`esh storage set <path>` / `esh storage use-internal`; `GET /v1/engine` reports it under
`storage`). Everything can run entirely from the internal drive. If the drive is disconnected, installs and
large reads pause rather than silently falling back.

## 8. Guardrails for the agent

- Loopback-only; respect esh's privacy/network policy.
- Never run pip/venv/Python CLIs directly (§ golden rule).
- Neutral naming in user-facing text: it's "3D animation," never "Pixar."
- Label non-commercial engines/models (CC-BY-NC): `sound-fx`, `music`, and the FLUX `kontext` image-edit
  backend. Default image edit (FLUX.2 Klein) is Apache-2.0 / commercial-safe.
- Deliver returned artifacts through your own media path.

## 9. Endpoint summary

| method + path | purpose |
|---|---|
| `POST /v1/route` | NL → RouteDecision |
| `POST /v1/route/resume` | resume after an install (`pendingId`) |
| `POST /v1/execute[?stream=1]` | run an ExecutionRequest (SSE when streaming) |
| `GET /v1/engines` | list engines + install state |
| `POST /v1/engines/install` · `GET …?id=` · `POST …/cancel` | install / poll / cancel an engine |
| `POST /v1/engines/remove` | remove an engine |
| `POST /v1/models/install` · `GET …?id=` · `POST …/cancel` | install / poll / cancel a model |
| `GET /v1/capability-models` | capabilities grouped by studio + installed backing models |
| `GET /v1/engine` | full health report (host, storage, engines, models, Apple Intelligence) |
| `POST /v1/audio/speech` · `POST /v1/audio/transcriptions` | TTS / STT (out of the box) |
