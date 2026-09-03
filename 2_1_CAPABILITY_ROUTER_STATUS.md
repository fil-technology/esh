# esh 2.1 — Capability Intent Router + Install-and-Resume: status

Spec: ClickUp 86eyucfbu. Architecture: `chat message + typed attachments → CapabilityIntent → independent
validation → RoutingOutcome → ExecutionPlan → typed result`.

## Done (tested, `Sources/EshCore/Routing/`)
- **CapabilityIntent** — canonical typed routing result (action/capability/inputRefs/arguments/alternatives/
  reason/provenance/confidence/plan). Confidence is untrusted metadata, never the execution gate (§2).
- **Tier 0 deterministic router** (§3) — data-driven route catalog (not a giant regex): modality+verb
  matching, verb+visual-noun generation detection ("generate a watercolor fox" → image.generate;
  "generate a poem" → chat), scale extraction ("2×"→2), agent-boundary → unsupported, ambiguous
  "improve/enhance/fix" → clarify, explicit multi-step → clarify with a proposed ordered plan.
  Conservative: executes only on a single high-signal match.
- **Independent validation + RoutingOutcome** (§8/§9) — `IntentResolver` validates against the registry
  (authority, not the router), install state, and asset presence; builds the ExecutionRequest; returns
  chat | ready | installRequired | clarify | unsupported. Missing component = first-class
  `InstallRequirement` (component/repo/size/fit).
- **Install-and-Resume** (§10) — `PendingCapabilityInvocation` + in-memory `PendingInvocationStore` +
  `InstallAndResumeService.record/resume`: after the component installs, the ORIGINAL request is
  re-validated with fresh state and executed — the user never repeats it. **Persistence: in-memory; does
  NOT survive a server restart** (honest first-cut limitation).
- **Routing benchmark** (§6/§7) — `RoutingBenchmark` dataset + harness with separated metrics
  (capability-selection accuracy, **false-execution rate** as the key gate, clarify precision/recall, chat
  & unsupported accuracy). Seed dataset covers explicit/paraphrase/ambiguity/multi/unsupported/chat.
  Seed result: **zero false executions**.

## Done — product wiring (§9/§10)
- **`POST /v1/route`** and **`POST /v1/route/resume`** — `CapabilityRouterService` turns message+attachments
  into a serializable `RouteDecision` (action + built ExecutionRequest for ready/installRequired +
  InstallRequirement + pendingId). Verified live under `esh serve` and `esh web`.
- **Web chat** routes-first: `handleRoute` calls `/v1/route`; `ready` → runs via `/v1/execute` + renders the
  typed artifact + "Why this execution plan?"; `installRequired` → an **Install-and-Resume card**
  ("<capability> needs one local component … [Install & continue]") that installs (esh model install for
  VLMs, or bridge auto-fetch for asset backends) then resumes via `/v1/route/resume`; `clarify`/`unsupported`
  → concise assistant message; `chat` → ordinary conversation. Audio-only keeps the existing transcribe flow.

## Done — Tier 1 constrained semantic router (§4/§5, first cut)
- **`CapabilitySchemaBuilder`** generates the router schema from the REAL registry (only capabilities with a
  provider, with arg schemas). **`SemanticIntentRouter`** protocol (pluggable) + **`ResidentLLMSemanticRouter`**
  (constrained JSON, zero extra download). `IntentResolver` escalates to Tier 1 ONLY on Tier-0 `clarify`; the
  proposal must name a registered capability or Tier-0's clarify stands (no false execution). Wired into
  `/v1/route` with the resident LLM; verified live (runs ~2.9 s, conservatively clarifies genuine ambiguity).

## Not yet done (next slices)
- **Router Auto** benchmarking (§5) — compare Apple Foundation Models / FunctionGemma / resident LLM on the
  routing benchmark (accuracy/latency/memory/cold-warm) and pick per Mac. The mechanism is pluggable; this is
  the measurement + selection policy.
- **LLM tool-calling front door** (§13) — adapt tool calls into the same validated routing path.
- **Multilingual** routing cases (§6); larger benchmark dataset (hundreds→thousands).
- **Durable** pending invocations (survive restart).

## Notes
- `audio.transcribe` currently has no registered capability provider (STT is exposed via
  `/v1/audio/transcriptions`, not the capability runtime) → the resolver honestly returns `unsupported`
  for it until an `audio.transcribe` provider is registered.
- Self-downloading providers (segment/generate/upscale) are surfaced via `InstallRequirement` when their
  asset is absent, so installs are explicit rather than silent (§10).
