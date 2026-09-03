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

## Router Auto — DONE (evidence-driven, spec §1–§16)
- **Dataset v2** (`RoutingDataset`): 58 labeled, adversarial, multilingual (EN/RU/HE) cases across every
  category + a 15-case quick subset. Versioned.
- **Asymmetric metrics** (`RoutingMetrics`): separated (correct capability/args/refs, false-exec, missed,
  unnecessary-clarify, chat/unsupported/clarify, per-language) + a documented conservative score
  (falseExec −6 ≫ missed −2 > unnecessary-clarify −1).
- **Benchmark harness + endpoint**: `POST /v1/route/benchmark?mode=tier0|tier1|hybrid|apple|apple-hybrid|
  gemma|gemma-hybrid` runs the dataset with live inference and persists **versioned evidence**
  (`RouterEvidenceStore`, provenance + freshness §13). All routers share ONE canonical schema (`SemanticRouting`).
- **Router Auto policy** (`RouterAutoPolicy`): explainable + conservative — a Tier-1 router is chosen only if
  available, fresh, ≤2% false-exec, AND beats the free/instant Tier-0 baseline; else Tier-0 + clarification.
  The live `/v1/route` honors it (no wasted escalation by default).

### Measured comparison (Apple M1 Pro / 32 GB, full v2 dataset)
| Router | Correct cap | False-exec | EN | RU | HE | Warm latency | Download | Verdict |
|---|---|---|---|---|---|---|---|---|
| **Tier-0 (rules)** | 0.48 | **0%** | 0.92 | 0.27 | 0.22 | **~0 ms** | 0 | **WINNER (safe, instant)** |
| resident-llm hybrid | 0.48 | 0% | 0.92 | 0.27 | 0.22 | 2477 ms | 0 | no gain over Tier-0, +latency |
| resident-llm tier1 | 0.00 | 0% | 0.21 | 0.09 | 0.11 | 2502 ms | 0 | useless as a router |
| apple-foundation tier1 | **0.70** | **36%** | 0.53 | **0.55** | **0.44** | 13653 ms | 0 | accurate+multilingual but **UNSAFE** (rejected) |
| functiongemma-270m (base) | 0.00 | 0% | 0.21 | 0.09 | 0.11 | 10514 ms | 318 MB | base needs fine-tuning |

- **Winner: Tier-0.** No Tier-1 router is both safe and better than the instant baseline. Apple FM has the
  best accuracy + multilingual but a **36% false-execution rate** (confidently wrong, no clarify discipline)
  → disqualified by the safety ceiling and worst conservative score. FunctionGemma base + the resident 3B
  can't follow the constrained routing format (capAcc 0). **Router Auto currently keeps Tier-0.**
- **Residency finding (§11):** non-resident router models pay ~10 s cold-load PER call (bridge reloads them);
  only a warm-resident router is viable. Apple FM is ~13.6 s/call on-device. So Tier-1 needs both quality AND
  warm residency to beat Tier-0.
- **Fallback ladder** (as evidence changes): Tier-0 → (eligible Tier-1 by score) → clarification. Today the
  middle is empty.
- **LLM tool-calling front door** (§13) — adapt tool calls into the same validated routing path.
- **Multilingual** routing cases (§6); larger benchmark dataset (hundreds→thousands).
- **Durable** pending invocations (survive restart).

## Notes
- `audio.transcribe` currently has no registered capability provider (STT is exposed via
  `/v1/audio/transcriptions`, not the capability runtime) → the resolver honestly returns `unsupported`
  for it until an `audio.transcribe` provider is registered.
- Self-downloading providers (segment/generate/upscale) are surfaced via `InstallRequirement` when their
  asset is absent, so installs are explicit rather than silent (§10).
