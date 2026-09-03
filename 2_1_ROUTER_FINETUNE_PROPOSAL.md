# esh 2.1 — Router fine-tune proposal (spec 86eyucfbu §14). PROPOSAL ONLY — not trained.

## Should we fine-tune a tiny router? — Yes, conditionally justified.
The measured evidence makes the case:
- **FunctionGemma-270m base**: capAcc 0.00 on our constrained schema (it needs task-specific fine-tuning, as
  Google states). But it is **tiny (318 MB, 8-bit)** — the only candidate that could plausibly be **warm-
  resident cheaply** (§11) and route in tens of ms once resident.
- **Apple FM**: accurate (0.70) + best multilingual (RU 0.55 / HE 0.44) but **36% false-exec** and ~13.6 s/call
  on-device — unsafe and slow as a router.
- **Tier-0**: safe + instant but English-only (RU 0.27 / HE 0.22) and misses hard paraphrases.

A **fine-tuned FunctionGemma** targeting our exact CapabilityIntent schema could combine Tier-0's safety with
Apple FM's multilingual recall, at warm-resident latency — the ideal Tier-1. This is worth pursuing **after**:
(a) a warm-router residency class exists (§11), and (b) the benchmark dataset is larger.

## Proposal (when approved)
- **Objective**: emit only `{action, capability, arguments, inputRefs}` from the canonical schema; strongly
  prefer `clarify` over a wrong `executeCapability` (bake the asymmetric cost into the training labels).
- **Dataset strategy**: synthetic generation from the capability registry (templated verbs × modalities ×
  args) + human-reviewed hard cases; **multilingual** (EN/RU/HE + more) via translation + native review;
  **hard negatives** (wrong-modality, agent-boundary, ordinary chat, injection text) labelled to their safe
  action; explicit **ambiguity** examples labelled `clarify`; **parameter extraction** (scale, resolution).
- **Splits**: train / dev / held-out **regression** suite = the current v2 dataset (never trained on) so we
  measure generalization; keep the asymmetric metrics + false-exec ceiling as the gate.
- **Eval**: must beat Tier-0's conservative score AND stay ≤2% false-exec on the held-out set, warm-resident,
  before it can be promoted by Router Auto.
- **Distribution/update**: ship as an optional esh-managed model; re-benchmark + re-stamp evidence on every
  release and after schema changes (freshness §13).

## Decision
Do NOT train yet. Prerequisites: warm-router residency class + a larger labeled multilingual dataset. Until
then Router Auto correctly keeps Tier-0. Revisit once residency lands.

## Update — fresh live evidence (2026-09-03) reprioritizes this
The full live benchmark (macOS 26.5.1, 58-case v2 dataset) sharpened the picture and **moves a
FunctionGemma fine-tune DOWN the priority list**:
- **Apple Foundation Models is the strongest Tier-1 candidate on every axis except safety**: capAcc 0.79,
  RU 0.64 / HE 0.78 (vs Tier-0's 0.27 / 0.22), **warm latency only ~2.15 s** (cold ~12 s), and a tiny
  esh-side footprint (~164 MB; the model lives in the OS system service). Its sole disqualifier is a **31%
  false-execution rate**.
- FunctionGemma-270m base still scores capAcc 0.00, is **slow (~10.5 s/call, not warm-resident here)**, and
  costs +318 MB — strictly worse than Apple FM on this Mac today.

**Therefore the highest-value next experiment is "make Apple FM safe"** (clarify-biased instruction + an
abstain / confidence gate + stricter validation-side rejection of low-signal proposals), NOT training
FunctionGemma. If Apple FM's false-exec drops ≤2% it becomes the Tier-1 winner and Router Auto promotes it
automatically from evidence — no training, no download. A FunctionGemma fine-tune remains a *fallback* path
worth pursuing only if the safety work on Apple FM fails AND a warm-resident tiny router is still wanted.
Still: **not trained.**
