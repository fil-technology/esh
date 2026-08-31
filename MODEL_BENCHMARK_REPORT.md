# esh Model Benchmark Lab — Report v1

Milestone: Model Benchmark Lab (ClickUp 86eyt9m3x). Determines which models are genuinely best for
esh on Apple Silicon from measured evidence + fit, not popularity. Reuses the M1 Optimization
Foundation harness; feeds `esh model recommended --explain`, onboarding, Model Fit, and the
Adaptive Scheduler.

## Honesty statement

This v1 delivers the **recommendation engine + dataset schema + integration**, and **local**
empirical measurement, but the environment it ran in could not download and benchmark large models
(internal disk was ~97% full; the pre-download fit gate correctly blocks that). So:

- **Cross-hardware curated quality/tool-reliability scores are NOT fabricated.** Recommendations are
  currently **fit-aware + capability-aware**, marked `estimated`, and are **upgraded to
  `measured-local`** for any model the user benchmarks with `esh optimize benchmark`.
- No "93.7%-best" fake precision is emitted anywhere.
- The candidate research below is real (live HuggingFace metadata at execution time); those models
  are queued for benchmarking on representative hardware with adequate storage, per the Phase 13
  validation gate, before entering a curated *measured* recommendation set.

## Candidate discovery (Phase 0 — researched live, 2026-08)

Verified against live HuggingFace metadata at execution time. Muse Glimmer-30B is a **candidate to
verify, not an assumed winner**.

| Candidate | Repo (mlx-community) | Real? | Notes |
|---|---|---|---|
| Muse Glimmer-30B | `Muse-Glimmer-30B-{4,5,6,8}bit`, `-bf16` | ✅ (35k dl) | 30B; ~17 GB @ 4-bit — benchmark on ≥32 GB; verify runtime + tool/JSON quality before recommending |
| Qwen3-30B-A3B-Instruct-2507 | `Qwen3-30B-A3B-Instruct-2507-4bit` | ✅ (103k dl) | MoE (A3B active) — strong speed/quality candidate |
| Qwen3.8-27B | `Qwen3.8-27B-4bit` | ✅ (112k dl) | current large Qwen |
| gemma-4-31b-it | `gemma-4-31b-it-4bit` | ✅ (45k dl) | large Gemma |
| Qwen2.5-Coder-14B | `Qwen2.5-Coder-14B-Instruct-4bit` | ✅ | coding candidate between 7B/32B |
| Llama-3.3-70B | `Llama-3.3-70B-Instruct-4bit` | ✅ | 64 GB+ class only |
| DeepSeek-R1-Distill-Qwen-32B | `DeepSeek-R1-Distill-Qwen-32B-4bit` | ✅ | reasoning candidate |

Reason each was included: current, high-download, MLX-converted, plausible for target Macs. These
supplement the already-shipped 26-entry catalog (all previously verified to resolve).

## Environment (first target machine)

- Apple M1 Pro · 32 GB unified memory · macOS 26.5.1 · hardware class **32–36 GB**
- MLX runtime: mlx 0.32.2 / mlx-lm 0.31.3 / mlx-vlm 0.5.0 (from `esh doctor`)

## Measured evidence (this Mac)

Through the real MLX inference path (`esh optimize benchmark`), preserved under
`~/.esh/optimization/`:

| Model | Strategy | decode | TTFT | peak mem | quality |
|---|---|---|---|---|---|
| Qwen2.5-0.5B-Instruct-4bit | kv.raw (baseline) | 245.2 t/s | 157 ms | 291.9 MB | 1.00 |

This local measurement is consumed by `esh model recommended --explain --profile fast`, which now
shows "★ measured on your Mac · ~245.2 tok/s decode" for that model (Phase 11 personalization).

## Recommendation engine (Phases 6–11)

- **Hardware classes** (Phase 1): 8/16/24/32-36/48/64/96+ GB (`HardwareClass`).
- **Profiles** (Phase 6): general, coding, reasoning, fast, low-memory, long-context, tools,
  best-quality (`RecommendationProfile`), scored **separately** (no universal score).
- **Fit-aware ranking** (Phase 7): excludes `unsupported`/`unlikely`; prefers `comfortable`/`fits`;
  `tight` allowed only for best-quality. Uses the M4 Model Fit gate.
- **Dataset** (Phase 8): `CuratedRecommendation` / `CuratedRecommendationDataset`, versioned
  (`datasetVersion`, `scoringVersion`), machine-readable via `esh model recommended --explain --json`.
- **Local override** (Phase 11): local `esh optimize benchmark` results supersede/annotate the
  generic ranking for that Mac; never uploaded.
- **`esh model recommended --explain`** (Phase 10): shows the pick per profile with fit, evidence
  provenance, and reasons.

Example (this Mac):

```
General     deepseek-r1-qwen-14b   [comfortable]  estimated (fit + capability)
Coding      mistral-small-24b      [fits]         estimated (fit + capability)
Reasoning   qwen-3-5-27b-...       [fits]         estimated (fit + capability)
Fast        qwen-2-5-0-5b          [comfortable]  ★ measured on your Mac (~245 t/s)
```

## Rejected / not-yet-recommended

No candidate was rejected on measured evidence yet (only one model measured). Muse Glimmer-30B and
the other researched candidates are **not** in the recommended set until they pass the Phase 13
gate (resolve + runtime-compatible + fit metadata + inference smoke + benchmark evidence for a
target class + no structured/tool regressions) on adequate hardware/storage.

## Limitations & next steps

- Empirical quality/tool-reliability/coding-correctness scoring across models and hardware classes
  is **not yet populated** — it requires downloading and benchmarking the candidate set on
  representative Macs with sufficient (ideally external) storage. The infrastructure to store and
  consume those scores exists (`CuratedRecommendation.qualityScore/toolReliability`,
  `measured-curated` evidence).
- The workload quality suite (JSON/tool correctness, coding tasks, long-context retention) beyond
  the M1 harness's JSON-validity + token-overlap proxy is a follow-up.
- When the Living Catalog (M6) lands, the curated dataset becomes independently refreshable/versioned.

## Freshness (Phase 12)

Recorded per benchmark: esh version, runtime version, model revision, optimization schema, workload,
context bucket, hardware fingerprint (see `OptimizationProfileKey`). Recommendations are dated via
the dataset's `generatedAt`/version fields; scoring version is `1`.
