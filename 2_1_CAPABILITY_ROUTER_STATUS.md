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

### Measured comparison (Apple M1 Pro / 32 GB, full v2 dataset, 58 cases — LIVE, 2026-09-03, macOS 26.5.1)
Numbers are from `POST /v1/route/benchmark` with live on-device inference; evidence persisted + versioned in
`router-evidence.json`. Warm = median steady-state call; Cold = first call (includes model load). Mem = peak
esh process-tree RSS sampled during the run.

| Router | capAcc | **False-exec** | Cons. score | EN | RU | HE | Warm | Cold | Mem peak | Download | Verdict |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **Tier-0 (rules)** | 0.48 | **0%** | **−0.14** | 0.92 | 0.27 | 0.22 | **~0 ms** | — | baseline | 0 | **WINNER (safe, instant)** |
| resident-llm hybrid | 0.48 | 0% | −0.14 | 0.92 | 0.27 | 0.22 | 10633 ms | 12370 ms | ~3300 MB | 0 | **no accuracy gain**, huge cost |
| resident-llm tier1 | 0.00 | 0% | −1.79 | 0.21 | 0.09 | 0.11 | 10657 ms | 10667 ms | ~1862 MB | 0 | useless as a router |
| functiongemma-270m tier1 | 0.00 | 0% | −1.79 | 0.21 | 0.09 | 0.11 | 10822 ms | 10514 ms | ~1854 MB | 318 MB | base needs fine-tuning |
| apple-foundation tier1 | **0.79** | **31%** | −1.48 | 0.55 | **0.64** | **0.78** | **2152 ms** | 12123 ms | ~164 MB* | 0 | accurate + multilingual + fast-warm but **UNSAFE** (rejected) |

\* Apple FM runs in the OS system-model service, so most of its memory is borne OUTSIDE esh's process tree;
the ~164 MB is only esh-side overhead. Its real footprint is shared OS state, not esh RAM.

- **Winner: Tier-0.** No Tier-1 router is BOTH safe (≤2% false-exec) AND better than the instant baseline
  (higher conservative score). `RouterAutoPolicy.choose()` on this evidence returns **no eligible Tier-1 →
  Tier-0 + clarification**: resident-llm & functiongemma score −1.79 ≤ Tier-0's −0.14 (they can't follow the
  constrained format, capAcc 0); apple-foundation is disqualified by the **31% false-execution rate** > the
  2% ceiling. The Capability Registry validator gates every path, so even a mis-proposing router cannot cause
  a false execution through `/v1/route` — the 31% is the router's *raw* proposal error, the reason it's not
  trusted to drive Auto.
- **Sharper conditional answer (which router, under what conditions):** Apple FM is by far the strongest
  Tier-1 candidate on every axis EXCEPT safety — best capAcc (0.79), best multilingual (RU 0.64 / HE 0.78 vs
  Tier-0's 0.27 / 0.22), **fast when warm (2.15 s)**, and a **tiny esh-side footprint**. Earlier notes that
  said "~13.6 s/call" conflated cold+warm: the cold *first* call is ~12 s, but **steady-state Apple FM is
  ~2 s** — latency is NOT the blocker. The single blocker is its **31% false-execution rate** (it executes
  when it should clarify/chat). So the highest-value next experiment is **making Apple FM safe** — a
  clarify-biased prompt + an abstain/confidence gate + stricter validation-side rejection — NOT fine-tuning
  FunctionGemma (base capAcc 0, slow, +318 MB). If Apple FM's false-exec drops ≤2%, it becomes the Tier-1
  winner and closes the RU/HE gap; Router Auto would then promote it automatically from evidence.
- **Hybrid is proven waste here:** resident-llm hybrid matched Tier-0 accuracy EXACTLY (escalated proposals
  were all rejected by validation) while adding ~10.6 s warm latency and a ~3.3 GB peak. Concrete evidence
  not to escalate to the resident 3B.
- **Fallback ladder** (as evidence changes): Tier-0 → (eligible Tier-1 by score) → clarification. Today the
  middle rung is empty by evidence.
- **Remaining:** make-Apple-FM-safe experiment (above); LLM tool-calling front door (§13); larger benchmark
  dataset (hundreds→thousands); durable pending invocations (survive restart).

## Notes
- `audio.transcribe` currently has no registered capability provider (STT is exposed via
  `/v1/audio/transcriptions`, not the capability runtime) → the resolver honestly returns `unsupported`
  for it until an `audio.transcribe` provider is registered.
- Self-downloading providers (segment/generate/upscale) are surfaced via `InstallRequirement` when their
  asset is absent, so installs are explicit rather than silent (§10).
