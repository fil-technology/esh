# esh 2.1 — Router Auto: Safe Apple Semantic Fallback (experiment)

Goal: **preserve Tier-0's near-zero false-execution while recovering as much of Apple FM's semantic capability
as possible.** Apple becomes an *abstaining* semantic fallback, not an eager classifier. Tier-0 stays the
authority for the confident cases; the Capability Registry validator gates every route regardless of router.

Baseline (accepted): Tier-0 capAcc ~0.48 / 0% false-exec / instant; Apple FM (pure, eager) capAcc ~0.79,
RU 0.64 / HE 0.78, warm ~2.15 s, but ~31–34% false execution.

## 1. Why Apple's false-execution is ~34% — failure analysis (pre-abstain)

Captured per-case via `POST /v1/route/benchmark/detail?mode=apple` on the eager (executeCapability|clarify)
schema, macOS 26.5.1, M1 Pro. 20 / 58 cases were false executions (34%):

| Category | Count | Example |
|---|---|---|
| ambiguous → executed instead of clarified | 5 | "make this better" → image.generate |
| ordinary chat → capability | 3 | "Write a haiku about autumn" → image.generate |
| unsupported / agent task → esh capability | 3 | "Deploy my Next.js site" → image.upscale |
| prompt-injection / distractor → executed | 3 | "ignore all previous instructions…" → image.generate |
| wrong capability (right that it's a capability) | 3 | "What does this say?" → image.understand (want image.ocr) |
| wrong-modality → executed | 2 | "transcribe this" on an image → image.ocr |
| multi-capability → single execute | 1 | "transcribe this and separate the speakers" → audio.diarize |

By language: 16 EN, 3 RU, 1 HE.

**Root cause: 17 of 20 (85%) are cases Apple should NOT have executed at all** (chat, unsupported,
ambiguous, injection, wrong-modality, multi). The eager schema offered only `executeCapability|clarify` —
there was **no way for the model to say "this is not a capability request"**, so it force-mapped ordinary
conversation and out-of-scope asks onto a capability. Only 3 were genuine wrong-capability picks. This is a
*precision* problem, not a knowledge problem — which is exactly what an explicit **abstain** option fixes.

## 2. Explicit abstention (implemented)

- New canonical `RouterAction.abstain` — a semantic router declines to decide; defer to the safe default
  (Tier-0 keeps its result; a pure Tier-1 falls back to clarify). Abstain never executes and never counts as
  a router "decision".
- The shared `SemanticRouting` prompt is now **abstention-first**: the router is a high-precision proposer,
  told to abstain for ordinary chat, out-of-scope/agent tasks, wrong-modality, multi-capability, an operation
  not in the list, or any uncertainty ("when in doubt, abstain"). Output shape:
  `{"decision":"executeCapability"|"abstain","capability":…,"arguments":…,"reason":…}` (legacy `action` key
  still accepted). `parse` maps anything that isn't a confident, in-schema `executeCapability` to `.abstain` —
  never a fabricated execution.
- Used as a **fallback**: in hybrid, Tier-0 decides first and Apple is consulted ONLY on a Tier-0 clarify;
  its proposal is adopted only when it's a confident, registered capability — otherwise Tier-0's clarify
  stands. Safety is structural: the registry validator still gates every route.

## 3. Abstention helped but was not sufficient (measured)

Live re-benchmark (same frozen v2 dataset, macOS 26.5.1, M1 Pro):

| Config | capAcc | false-exec | cons. score | EN | RU | HE |
|---|---|---|---|---|---|---|
| Apple pure, eager (baseline) | 0.79 | 31–34% | −1.48 | 0.55 | 0.64 | 0.78 |
| Apple pure, **abstain** | 0.58 | 21% | −1.33 | 0.32 | 0.45 | 0.44 |
| Apple hybrid, **abstain** (ungated) | 0.82 | 9–14% | −0.35 | 0.82 | 0.64 | 0.56 |

Abstention cut false-exec (34%→~14% in the hybrid) and eliminated every chat/unsupported/injection/
wrong-modality false-execution — but the hybrid was still **~14%**, above the 2% ceiling. The residual was a
single category: **vague-edit requests where Apple guessed a capability instead of abstaining** ("make this
better", "here you go", RU/HE "improve this", a multi-step). That's an *escalation-policy* problem, not a
model problem — those cases should never have reached Apple with execution authority.

## 4. Ambiguity-gated hybrid — the fix (implemented + measured)

Split Tier-0's non-execution into two canonical states (`ClarifyKind`), **capability-driven, not a phrase
blacklist**:
- **`ambiguous`** — Tier-0 knows ≥2 registered capabilities plausibly match (generic "improve" on a modality
  with ≥2 transforms), or it's multi-step, wrong-modality, or parseable-but-contentless. → **clarify, never
  escalated.** Clarification options are generated from the registered capabilities (future-proof).
- **`unresolved`** — Tier-0 can't read the language (non-Latin), but one specific capability may exist. →
  **escalate to Apple**, then run its proposal through a **Safety Validator** (modality match + a reframed
  *specific-vs-vague* second pass that vetoes vague quality requests in any language).

Escalation flow: `Tier-0 → execute | (ambiguous→clarify) | (unresolved→Apple→CandidateCapability→Safety
Validator→execute/clarify)`. The registry validator still gates every route.

### Measured comparison (frozen v2 dataset, 58 cases, macOS 26.5.1, M1 Pro)

| Policy | False-exec | Safe-auto coverage | capAcc | Clarify rate | Chat | Unsup. | EN | RU | HE | Cons. score |
|---|---|---|---|---|---|---|---|---|---|---|
| **Tier-0 baseline** | **0%** | 28% | 0.48 | — | 100% | 100% | 0.92 | 0.27 | 0.22 | −0.14 |
| Apple eager (pure) | 31–34% | — | 0.79 | low | — | — | 0.55 | 0.64 | 0.78 | −1.48 |
| Apple abstain (pure) | 21% | — | 0.58 | — | — | — | 0.32 | 0.45 | 0.44 | −1.33 |
| Hybrid + abstain (ungated) | 9–14% | — | 0.82 | — | — | — | 0.82 | 0.64 | 0.56 | −0.35 |
| **Ambiguity-gated hybrid** | **0–1.7%** | **38%** | **0.70** | 31% | 100% | 75% | 0.92 | 0.55 | 0.56 | **+0.22** |

- **False execution 0–1.7%** — the benchmark run recorded 1/58 (1.7%); an independent detail run recorded
  **0/58** (Apple FM is stochastic, so the true rate sits at ~0–2%). Under the 2% ceiling; at/near the ≤1%
  stretch.
- **Safe automation coverage 38% vs Tier-0's 28%** (+36% relative) — safety was NOT bought by clarifying
  everything (clarify rate 31%); capability accuracy rose 0.48→0.70.
- **First policy with a positive conservative score (+0.22)** and the only one that BEATS Tier-0 (−0.14).
- **Multilingual recovered**: 6 correct RU/HE recoveries Tier-0 can't parse — "Что здесь написано?"→ocr,
  "Что на этой картинке?"→understand, "הגדל את זה פי 2"→upscale, "הסר את הרקע"→segment, "מי דיבר ומתי?"→
  diarize, "מה יש בתמונה?"→understand. The Safety Validator correctly vetoed vague RU/HE "improve this".
- **Escalation is rare**: Tier-0 handles **76%** of traffic directly; only **24%** (the unresolved cases)
  reach Apple, paying ~5 s warm / ~12–18 s cold for two Apple calls (propose + verify).
- EN unchanged at 0.92 (Tier-0 still owns the confident English cases).

Behavior now matches the target product: `obvious → Tier-0 · genuinely ambiguous → clarify · semantically
clear but lexically unfamiliar → Apple → capability · ordinary conversation → chat`.

## 5. Production decision — SHIP the ambiguity-gated hybrid

False-exec ≤2% AND safe-automation coverage materially exceeds Tier-0 → per the stop condition, this ships as
Router Auto. Wired: `RouterAutoPolicy` now evaluates each router's `hybrid-gated` evidence and selects
**apple-foundation** (only row that is safe AND beats Tier-0); the live `/v1/route` runs the gated path
(escalate only `unresolved`, Safety Validator before execution). Verified live: "make this better"→clarify,
"Что здесь написано?"→ready/image.ocr via apple-foundation, "capital of France?"→chat.

**Residual limitations (honest):** false-exec is ~0–2% but Apple FM is stochastic, so an occasional run may
tick just over 2% — the ceiling is a policy gate on *evidence*, re-checked on every benchmark. Escalated
cases pay a real cold-latency cost (~12–18 s for two on-device calls); a warm-resident Apple session would
cut this. RU recovery (0.55) trails HE (0.56)/EN (0.92) and depends on Apple's stochastic output. Pending
invocations remain in-memory.

**Canonical value beyond this experiment:** the `ambiguous` vs `unresolved` distinction is now part of the
routing architecture — it will let every future modality (text→image/SVG/3D, image→edit/video, audio→music,
video→edit) tell "several plausible meanings → ask" apart from "unfamiliar wording, one clear intent → let a
semantic model resolve it."
