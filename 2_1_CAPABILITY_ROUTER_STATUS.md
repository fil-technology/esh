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

## Not yet done (next slices)
- **Tier 1 constrained semantic router** (§4/§5) — dynamic capability schema from the registry, sent to a
  router model (Apple Foundation Models / FunctionGemma / resident LLM), result validated independently.
  Includes **Router Auto** benchmarking (accuracy/latency/memory/cold-warm) to pick the router per Mac.
- **Product wiring** — a `/v1/route` endpoint and/or chat integration (install card UI + resume button),
  so the router drives real conversations.
- **LLM tool-calling front door** (§13) — adapt tool calls into the same validated routing path.
- **Multilingual** routing cases (§6); larger benchmark dataset (hundreds→thousands).
- **Durable** pending invocations (survive restart).

## Notes
- `audio.transcribe` currently has no registered capability provider (STT is exposed via
  `/v1/audio/transcriptions`, not the capability runtime) → the resolver honestly returns `unsupported`
  for it until an `audio.transcribe` provider is registered.
- Self-downloading providers (segment/generate/upscale) are surfaced via `InstallRequirement` when their
  asset is absent, so installs are explicit rather than silent (§10).
