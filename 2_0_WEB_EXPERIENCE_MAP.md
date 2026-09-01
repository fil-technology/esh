# esh 2.0 Web Experience — Design → API Implementation Map

**Date:** 2026-09-01
**Design source of truth:** `UI mockups for web system.zip` — `esh Prototype.dc.html` (interaction) +
`esh 2.0 UI System.dc.html` (components) + `CLAUDE.md` (visual rules).
**Product intent:** ClickUp 86eytj9rg. **Runtime truth:** this repository.

## Visual language (from the prototype's inline styles + CLAUDE.md)
- Paper: `#fbfaf8`; ink: `#201e1b`; muted: `rgba(32,30,27,.4–.75)`; warm panel: `#f7f4ee`/`#f3f1ec`;
  user bubble `#efede8`. **Amber only for warnings:** `#b0761f`.
- Type: `-apple-system, system-ui` for prose; **IBM Plex Mono** for engine/technical data.
- **No emoji** — inline stroke SVG icons (`stroke:currentColor`). Rounded corners (7–15px). Subtle borders.
- Thin client only: **no routing / fit / scheduler / cache / capability logic in JS.**

## Architecture
Keep the current self-contained single-page approach (served by `esh web`, no Node build → packages
into the notarized binary, loopback-only preserved). The SPA is a thin client over new canonical
JSON endpoints that each wrap an EXISTING backend service.

---

## Component → backend map

| Design component / state | Backend source of truth | HTTP endpoint | Status |
|---|---|---|---|
| **Onboarding** (Mac, Apple, MLX/llama.cpp, SSD, recommended model) | `DoctorService`, `HostMachineProfileService`, `OnboardingService`, `RecommendedModelRegistry` | **NEW** `GET /v1/onboarding` (or reuse `GET /v1/doctor`) | add |
| **Chat streaming** | `OpenAICompatibleService.chatCompletionsStreamProvider` | `POST /v1/chat/completions` (SSE) | exists |
| **Reasoning** collapse "▸ Reasoning · 12s" | model `<think>` + client timing | (in stream) | exists (rc.1) |
| **Tools** "✓ Read file" | canonical tool events | (in stream) | tools gated on inference path today → render only real events; none fabricated |
| **Per-response meta → Execution panel** (backend, TTFT, tok/s, tokens, memory, context, residency, prompt/KV cache) | `ExecutionProfile`, `EshUsage`, residency probe | **NEW** final SSE `event: execution` (or `x-esh-*` trailer) carrying ExecutionProfile+usage | add |
| **"Why this model?"** rationale | `SchedulerService.decide` → `SchedulerDecision.rationale` | **NEW** `GET /v1/schedule?goal&quality&latency…` | add (wraps `esh schedule --json`) |
| **Model picker**: Auto + Optimize (Balanced/Quality/Speed/Low-Memory) + installed + resident + Apple + Browse/Manage | installed models + residency + `AppleProvider` | extend `GET /v1/models` → add `resident`, `backend`, `apple`, `capabilities`; Auto/optimize handled by `GET /v1/schedule` | extend |
| **Model browser**: catalog rows (name/badge/desc/fit/mem/speed/install), filter chips, "● measured on this Mac" | `RecommendedModelRegistry`, `ModelFitService`, `ModelBenchmarkLabStore` | **NEW** `GET /v1/catalog?filter=` | add |
| **Model detail + Fit** (Comfortable/Tight/…, download, expected memory, Mac memory, context, speed, tight warning, install→destination) | `ModelFitService.assess`, `SystemStorage`, benchmark | **NEW** `GET /v1/catalog/{id}` | add |
| **Install with progress** | `HuggingFaceModelDownloader` / model install | **NEW** `POST /v1/models/install` (SSE progress) | add |
| **Engine inspector** (memory, pressure, loaded/resident models, caches, storage, MLX/llama.cpp/Apple) | host profile, `RuntimeLifecycleManager` residency, `SystemStorage`, capabilities | **NEW** `GET /v1/engine` | add |
| **Status line** "Local · Private · Ready" | engine health + selected model + storage | `GET /v1/engine` | add |
| **Settings** (General/Intelligence/Models/Voice/Performance/Storage/Privacy/Advanced) | `EshConfig` (TOML) | **NEW** `GET /v1/config` + `POST /v1/config` | add |
| **Performance** (Auto/Speed/Balanced/Low-Memory) | maps to config perf mode / schedule quality-latency | `GET/POST /v1/config` | add |
| **Storage** (root, used/free, models/caches/speech, move, disconnected) | `SystemStorage`, storage config | `GET /v1/engine` (storage block) + config | add |
| **Privacy** (on-device, network scope, Apple PCC labeling) | static truths + Apple availability | `GET /v1/engine` (apple) | add |
| **Voice** (mic→STT→LLM→TTS, playback, Auto voice/language, read-aloud toggle) | `/v1/audio/transcriptions`, `/v1/audio/speech`, chat | exists (rc.1) | exists |
| **Structured output** (Text/JSON/JSON-Schema/Constrained, strict rejection) | `CapabilityResolver` via request `response_format` | `POST /v1/chat/completions` | exists |
| **Request Inspector** (Request→Capability→Scheduler→ExecutionProfile→Response; applied/transformed/ignored/unsupported) | `CapabilityResolution` + `SchedulerDecision` + `ExecutionProfile` | reuse `/v1/schedule` + execution event | add |
| **Degraded**: memory pressure, SSD lost, model-load failure, no model, Apple unavailable, low disk, worker crash, speech unavailable, strict-unsupported | real errors from the above | surfaced via `GET /v1/engine` + request errors | add/honest |
| **API server card** (endpoint, native/OpenAI/Anthropic, auth, bind) | server config | `GET /v1/engine` (server block) | add |

## New endpoints to add (all wrap existing services — no new logic)
1. `GET /v1/engine` — host, memory+pressure, residency (loaded models), caches, storage, backends, server, apple, update.
2. `GET /v1/catalog[?filter=]` — recommended catalog with fit + benchmark(measured vs estimated) + installed/resident.
3. `GET /v1/catalog/{id}` — one model: capability scores, fit assessment, download/memory/context/speed, storage destination.
4. `GET /v1/schedule?goal&quality&latency&context&tools&vision` — SchedulerDecision incl. rationale ("Why this model?").
5. `GET /v1/config` + `POST /v1/config` — read/update `EshConfig` (settings that belong to esh, not the browser).
6. `POST /v1/models/install` — SSE download progress.
7. Chat stream **execution event** — a final `data:` frame with ExecutionProfile + usage so the Execution panel is real.
8. `GET /v1/onboarding` — convenience bundle for the onboarding flow (or reuse doctor).

Browser-local (localStorage) only for genuinely presentation-only prefs: sidebar open, last-open pane,
conversation history (already local). Everything cross-client (models, speech models, perf, storage)
persists via `/v1/config`.

## Honest gaps (never faked)
- **Tools on the inference path are gated today** (capability contract rejects them). The UI renders
  only real tool events; with none emitted, the tools row simply does not appear. The full agentic
  tool-approval flow is the separate post-2.0 M12 (Ashex boundary preserved).
- **ExecutionProfile** exists internally; it must be surfaced in the HTTP response before the panel is
  fully real. Until then the panel shows the fields the stream provides and omits the rest — never
  fabricated numbers.
- **Measured vs estimated** benchmark data comes from `ModelBenchmarkLabStore`; models without local
  measurements are labeled "estimated" and never given a fabricated "● measured" mark.

## Delivery
Branch `codex/web-experience-2.0`. Build backend endpoints → rewrite `WebChatPage` as the faithful
SPA → wire → test (unit + API + real browser) → visual QA vs prototype → packaged `esh web` smoke →
ship in **rc.2** (rc.1 is tagged separately; this does not mutate it).
