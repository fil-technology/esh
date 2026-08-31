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

## Remaining for full M8

- **Streaming events — producer/consumer wiring.** The canonical envelope + text adapter exist and
  are tested (`ChatService.streamEvents`). Remaining: have `esh serve` and the Terminal UX/Web Chat
  consume `EshStreamEvent` instead of raw text chunks, and add `.usage`/`.reasoningDelta` emission
  from producers that can observe them.
- **Attachments / multimodal** typed inputs (images/documents/audio) with honest unsupported
  reporting. Deliberately deferred rather than blanket-rejected, because the MLX-VLM bridge *can* do
  vision for VLM models — needs per-model capability resolution to avoid mis-reporting.
- **Cache state as a first-class runtime signal** — runtime reporting KV/prompt-cache hit/miss + cache
  memory back into `ExecutionProfile`/`EshUsage.cachedInputTokens` (currently the profile records the
  chosen strategy, not the realized hit/miss).
- **Apple Foundation Models as a first-class contract provider.** Today `AppleIntelligenceService`
  is honest and safe as a *separate* provider: availability + reason surfaced (doctor/onboarding/
  `esh apple`), `onDevice` flagged with PCC called out as a distinct semantic, and `generate()`
  throws rather than silently degrading when unavailable. It is structurally impossible for an
  explicit downloaded-model request to become Apple (Apple is not in the backend registry).
  Remaining: make Apple participate through `ExternalInferenceService`/the canonical contract with
  honest capability resolution (Apple exposes no custom sampling params or GBNF; guided generation is
  its own mechanism), a `localOnly` guarantee that provably cannot reach PCC/cloud, and Apple as a
  measured scheduler candidate. This is a design-consequential addition (how Apple maps onto the
  contract) — deferred pending that decision, not stubbed.
- **Conformance harness across backends** — the resolver layer is unit-tested; a cross-backend
  conformance suite driving real inference (text, streaming, strict json_schema on GGUF, unsupported
  structured behavior on MLX, generation params, cancellation, usage accounting) is the next step.

## Verdict

M8 is **advanced but not complete**. The headline honesty guarantee is met: **native constrained
decoding is real on GGUF and strict callers are satisfied natively, while backends without it reject
rather than pretend.** Tools, usage, and reasoning are modeled with truthful capability resolution.
Streaming events, attachments, realized cache state, Apple-as-provider, and the cross-backend
conformance harness remain — and a live GGUF constrained-decoding smoke test is still pending.
