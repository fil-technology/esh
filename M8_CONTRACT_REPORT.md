# M8 — Inference Contract v2 Report

Status of the esh-native inference contract on branch `codex/m8-contract` (targets 0.9.0). This
report separates **implemented + verified**, **backend-specific limitations**, **approximated**, and
**remaining** — so nothing is called complete merely because the Swift types exist.

The contract is the single canonical representation; the OpenAI/Anthropic/Ollama compatibility layers
adapt onto it, never the reverse.

## Implemented + verified (unit-tested, build green, 240 tests)

| Area | What | Verification |
|---|---|---|
| **Structured output — native** | On GGUF (llama.cpp), `json` / `json_schema` / `grammar` resolve to `.applied` and are enforced by native constrained decoding (`--json-schema` / `--grammar`). Strict callers are **satisfied natively, not rejected**. | `CapabilityResolverTests`: `ggufJSONSchemaIsAppliedNativelyCarryingTheSchema`, `ggufStrictJSONSchemaIsAppliedNotRejected`, `ggufGrammarIsAppliedNativelyWhenProvided` |
| **Structured output — honest fallback** | On MLX/ONNX (no native constrained decoding), non-strict json/json_schema is `.approximated` via a labeled prompt instruction; **strict is `.rejected`**, never silently approximated. | `strictJSONIsRejectedNotApproximated`, `onnxHasNoNativeConstrainedDecoding` |
| **Capability resolution** | Every classified option carries native/transformed/approximated/ignored/rejected + a human detail. Strict + any rejection → the request fails (`ExternalInferenceService`), not a silent unconstrained fallback. | resolver suite + `strictJSONSchemaIsRejected` |
| **Tools** | Canonical `EshToolDefinition` / `EshToolChoice` / `EshToolCall` on request+response. Requested tools are **honestly reported `.rejected`** (no native function-calling on the local runtime yet; `esh agent` orchestrates tools separately) — not silently dropped. | contract round-trip tests |
| **Reasoning** | Explicit thinking toggle resolves per backend: MLX `.applied` (passed into the model chat template as `enable_thinking`); llama.cpp/ONNX `.ignored` (no toggle; model/template decides, thinking inline). Only reported when the caller sets it. | `reasoningIsAppliedOnMLX`, `reasoningIsIgnoredOnGGUFNotFakedAsApplied`, `reasoningNotReportedWhenCallerDidNotAskToToggle` |
| **Usage accounting** | `EshUsage` on the response: measured `inputTokens`/`outputTokens`/`totalTokens` (MLX bridge now emits `promptTokens`/`generationTokens` from the runtime's `GenerationResponse`), plus `contextUsed`. Total derived only when both halves are measured. Local monetary cost = 0 with explicit `costProvenance`, kept distinct from resource usage. No fabricated counts — llama.cpp leaves token counts nil. | **real MLX inference**: `usage` reports `inputTokens/outputTokens/totalTokens` end-to-end |
| **Streaming events** | Canonical `EshStreamEvent` envelope (`textDelta`/`reasoningDelta`/`toolCall`/`usage`/`done`/`failed`) + `ChatService.streamEvents` adapting the real runtime text stream: `.textDelta` per chunk, terminal `.done`/`.failed`, cancellation surfaced as a thrown `CancellationError`. Only genuinely observed events emitted (text today); richer events reserved for producers that supply them. | `StreamEventTests`: deltas→done, empty-chunk suppression, error→terminal `.failed` |
| **Execution metadata** | `ExecutionProfile` reflecting the KV/prompt-cache strategy that actually ran is attached to every response (from 0.7.0), plus truthful `residency` (weights-resident vs handle-cached) for this execution. | `OptimizationTests`, response round-trip, `M8ConformanceTests` |
| **Realized cache state** | Distinct from the chosen strategy: the runtime reports the actual prompt-cache outcome per request (`cacheHit` + `cachedTokens` reused), surfaced on `Metrics`, `EshUsage.cachedInputTokens`, and `ExecutionProfile.cacheHit`. | **real MLX inference**: `cacheHit`/`cachedInputTokens` end-to-end |
| **Attachments** | Typed `EshAttachment` (image/document/audio/other) on the request; resolved **honestly as rejected** (never silently dropped), with a reason distinguishing a model-capability gap from an esh-execution gap. | `imageAttachmentIsRejectedNotSilentlyDropped`, `imageAttachmentReasonDistinguishesModelCapabilityFromEshGap` |
| **Cross-backend conformance** | A consolidated conformance suite asserts the honesty invariants uniformly across backends + full-request/response serialization. | `M8ConformanceTests` (7 tests) |
| **Backward compatibility** | Additive optional fields; pre-M8 infer request JSON still decodes (`decodeIfPresent` throughout). | `legacyRequestWithoutResponseFormatStillDecodes` |

## Backend-specific limitations (documented, not hidden)

- **Native constrained decoding is GGUF-only.** MLX and ONNX honestly approximate/reject. MLX
  logit-processor constrained decoding is a future upgrade; until then MLX strict structured output
  is rejected, by design.
- **Reasoning-token usage is not separately observable** on llama.cpp or the MLX bridge, so
  `EshUsage.reasoningTokens` stays `nil` rather than being invented.
- **Tool calls are not produced by the runtime** (`toolCalls` is nil); tool orchestration lives in
  `esh agent`. The contract models tools so adapters and future native tool-calling map cleanly.

## Not yet verified end-to-end (honest gap)

- **GGUF native constrained-decoding e2e smoke test is NOT run on this machine.** The wiring
  (`CapabilityResolver` → `GenerationConfig.jsonSchema/grammar` → `llama-cli --json-schema/--grammar`)
  is implemented and unit-verified, and `llama-cli` is present with the flags, but **no GGUF model is
  installed locally** (only MLX/safetensors), so a live constrained generation has not been executed.
  Tracked follow-up: install a small GGUF (e.g. qwen2.5-0.5b Q4, ~350 MB) and assert schema-conformant
  output. Not auto-downloaded here due to download-permission policy and disk pressure (~13 GB free).

## Recently completed (0.9.x)

- Realized cache state as a first-class signal; typed attachments with honest rejection; cross-backend
  conformance suite; truthful residency (weights-resident) surfaced via the persistent MLX worker.

## Apple — provider vs routable backend

Apple now **participates in the capability contract** (`esh capabilities` → `appleProvider`): honest
availability + reason, `onDevice`, `permitsCloudOrPCC=false` and `neverAutoSelected=true` (both
guaranteed by construction — esh only ever uses `SystemLanguageModel.default`, never a PCC/cloud
path), with contract limitations listed rather than hidden. The safety guarantees the user required
are met and tested.

**Deferred (design-consequential, needs a product call):** making Apple a *routable/schedulable*
`BackendKind` that competes with local models in `infer`/the scheduler. This touches ~16 exhaustive
`BackendKind` switch sites and raises product questions (should Apple auto-compete? how does
`localOnly` interact with any future PCC option?). It is deferred deliberately, not stubbed — Apple
stays explicitly-selected-only via `esh apple` until that decision.

## Remaining for full M8

- **Streaming events — producer/consumer wiring.** The canonical envelope + text adapter exist and
  are tested (`ChatService.streamEvents`). Remaining: have `esh serve` and the Terminal UX/Web Chat
  consume `EshStreamEvent` instead of raw text chunks, and add `.usage`/`.reasoningDelta` emission
  from producers that can observe them.
- **Attachment execution** (not just honest rejection): feed images to VLM models through the MLX-VLM
  path. Today attachments are typed and honestly rejected; actual multimodal execution is a follow-up.
- **Live GGUF constrained-decoding smoke test**: wiring is unit-verified but not yet run against an
  installed GGUF (none present locally).

## Verdict

M8's honesty contract is **substantially complete and verified**: native constrained decoding real on
GGUF (strict satisfied natively, others reject rather than pretend), canonical tools, measured usage,
per-backend reasoning resolution, canonical streaming events, realized cache state, typed attachments
with honest rejection, truthful residency, Apple as an honest on-device contract provider, and a
cross-backend conformance suite. Remaining are execution-wiring items (streaming consumers, VLM
attachment execution, a live GGUF smoke) and the design-consequential Apple-routable-backend decision
— all tracked, none misrepresented.
