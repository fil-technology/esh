# esh Roadmap Gap Audit (post-v0.6.0)

Honest audit of `main` after the v0.2–v0.6 release train. Several milestones were delivered as
**slices**, not complete milestones. This document records exactly what is complete vs. a slice vs.
not started, so nothing downstream is falsely treated as finished. Verified against actual code.

## Summary

| Area | Status | Evidence / gap |
|---|---|---|
| M1 Optimization Foundation | **complete (v0.3.0)** | strategy boundary, ExecutionProfile, planner, harness, profile DB, `esh optimize` |
| M3 Storage v2 | **complete (v0.2.0)** | `esh storage`, external SSD, marker/disconnect |
| M4 Model lifecycle + Fit gate | **complete (v0.2/0.3)** | catalog, import/scan, 6-class fit gate |
| M5 Onboarding + Doctor | **complete (v0.2/0.3)** | `esh onboard`, `doctor --json` |
| M6 Update system | **SLICE** | only `esh update check` (notify-only). Living catalog / versioning / rollback / channels **not done** |
| **M7 Runtime Lifecycle / Warm Pool** | **NOT STARTED** | no loaded-model registry, warm/cold state, idle/pressure eviction, bounded concurrency, cancellation infra, priorities. `SchedulerService` takes resident-models as a param defaulting to 0 |
| **M8 Inference Contract v2** | **SLICE (v0.5.0)** | only `response_format` + capability resolution (applied/transformed/ignored/rejected). See gaps below |
| M8.5 Web Chat | **NOT STARTED** | |
| **M9 Adaptive Scheduler** | **v1 slice (v0.6.0)** | selection + rationale works, but consumes only heuristic capability metadata + fit + M1 evidence; no warm-pool awareness, no benchmark-lab dataset yet |
| Model Benchmark Lab | **NOT STARTED** (this milestone) | candidate discovery done (research); harness reuse + curated dataset pending |
| Terminal UX (first-class) | **NOT STARTED** | current TUI is functional but not Claude-Code-quality |
| M10 Speech | **partial** | TTS exists; STT is a stub |
| M11 Hardening / 2.0 | **NOT STARTED** | |

## M8 Inference Contract v2 — what's missing (do NOT call M8 complete)

Delivered: `response_format` (text/json/json_schema/grammar) + `CapabilityResolution`
(applied/transformed/ignored/rejected) on the native infer path. **Missing:**
- **Thinking/reasoning** normalization in the contract response (GenerationConfig has
  `enableThinking`/`thinkingBudget` inputs, but reasoning usage/mode is not normalized in the
  response).
- **Tools / function calling** as first-class native contract (tool defs, tool_choice, tool
  messages, parallel calls). The OpenAI compat handler stubs tools; the native contract does not
  model them.
- **Attachments / multimodal** typed inputs — none.
- **Streaming event model** — the server is buffered, not a normalized incremental event stream.
- **Token/usage breakdown** — `Metrics` has ttft/tok-s/memory only; no input/output/reasoning/
  cached/total token accounting or context-used/limit.
- **Cost/resource provenance** — none ($0-local vs provider cost not modeled).
- **Extended execution metadata on responses** — ✅ (0.7.0) `ExecutionProfile` reflecting the KV/
  prompt-cache strategy that actually ran is now attached to `ExternalInferenceResponse`. Still to
  add: normalized token usage + reasoning/cache-hit metadata on the profile.

## M9 Scheduler — what's a slice

Works: capability request → fit-aware, evidence-aware model + ExecutionProfile + rationale; Apple
suggestion; honest "no model" path. **Slice because:** capabilities for installed models come from
catalog match or name heuristics (not measured); no warm-pool/live-pressure input (M7); model
ranking uses parameter-size proxy + M1 KV evidence, not Benchmark-Lab quality/tool-reliability
scores (Benchmark Lab feeds this next).

## Structured / constrained generation

Currently **instruction approximation** (`CapabilityResolver` injects a JSON instruction and reports
`transformed`), honestly labeled "not guaranteed." **Missing:** native backend mechanisms — llama.cpp
GBNF / LLGuidance, MLX constrained decoding / logit processors — behind the `EshResponseFormat`
abstraction. When those land, json_schema should resolve to `applied` (native) instead of
`transformed` (approximated).

## KV / prompt / prefix cache

The M1 planner selects a KV strategy (raw/turbo/triattention) and a prompt-cache strategy, and
`ExecutionProfile.cacheMode` maps to the runtime. **Missing:** the runtime reporting cache **hit/miss
+ cache memory** back into the response/ExecutionProfile, and surfacing that in doctor/scheduler.
Cache status is not yet a first-class runtime signal.

## Apple Foundation Models

Done: detection (doctor/onboarding), on-device generation (`esh apple`), scheduler *suggestion*.
**Missing:** benchmarking Apple through the harness, Apple as a first-class capability provider in
the contract/`esh capabilities`, and Apple as a scheduler candidate that competes on measured
evidence (currently only a fallback suggestion).

## Conclusion

M8 and M9 are **not complete** and are documented as slices. The next foundational work is: the
**Model Benchmark Lab** (feeds recommendations + scheduler), then filling the M8 contract, native
structured generation, cache status integration, M7 warm pool, and the update living catalog —
before Terminal UX and Web Chat consume them.
