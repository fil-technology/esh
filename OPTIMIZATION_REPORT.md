# esh Optimization Foundation — Report (M1)

Milestone 1 of the delivery roadmap (ClickUp 86eyt92j7 / 86eyt96nn). Builds the pluggable
optimization boundary + evidence-driven benchmark harness that later dependency/runtime/model/
scheduler decisions consume. Companion engineering doc: [docs/OPTIMIZATION.md](docs/OPTIMIZATION.md).

**Core rule honored:** no optimization becomes a default because it *sounds* faster. A strategy is
eligible for `auto` only after the local benchmark harness measures its real benefit, memory cost,
compatibility, and quality on this runtime/model/hardware, and it clears the quality floor.

---

## 1. Architecture (what was built)

```
request → model/backend resolution → OptimizationPlanner → ExecutionProfile → backend execution
```

- **`OptimizationStrategy`** (`Sources/EshCore/Optimization/OptimizationTypes.swift`) — a strategy is
  *data*: id, category, backend/model/runtime constraints, quality-change/distribution-equivalent
  flags, estimated memory delta, and `requiresBenchmarkBeforeAuto`. A new technique is added by
  registering another value, not by editing inference orchestration.
- **`OptimizationStrategyRegistry`** — built-ins represent esh's **existing** behavior behind the
  boundary: KV-cache family (`kv.raw` baseline / `kv.turbo` = TurboQuant / `kv.triattention`) mapped
  onto the existing `CacheMode`, and a prompt/prefix-cache family (`prompt.reuse` / `prompt.off`).
  A `spec.draft` speculative-decoding descriptor is registered as a *future* candidate with no
  backend, proving new families slot in without touching orchestration. **TurboQuant is a candidate
  behind the boundary, not a hard-coded product concept.**
- **`ExecutionProfile`** — serializable resolved plan (backend, model, mode, workload, per-category
  selections, ordered reasons, `evidenceBacked`, profile version). Human + stable JSON; maps back to
  the existing `CacheMode` knob so backends consume it without a rewrite.
- **`OptimizationPlanner`** — evidence-driven `auto/speed/balanced/memory`. The quality floor applies
  in **every** mode; modes differ only in objective (auto = best validated; speed = decode t/s;
  memory = lowest peak; balanced = conservative). With no evidence, falls back to conservative
  known-good baselines and says so.
- **`BenchmarkHarness` + `ProductionBenchmarkRunner`** — runs strategies × scenarios through the
  **real** `ExternalInferenceService` (same path as CLI/server), warmup + repetitions, median +
  preserved raw samples, JSON-validity + token-overlap quality proxy. No metric is synthesized.
- **`OptimizationProfileStore`** — persists raw results on the internal state root, keyed by
  hardware fingerprint + model + backend + runtime version + optimization schema version. A key
  mismatch is the invalidation mechanism (stale results are never applied).
- **CLI**: `esh performance <auto|speed|balanced|memory>` and
  `esh optimize status|strategies|plan|benchmark|compare|reset` (all `--json`).

---

## 2. Initial benchmark matrix (real, measured)

Run through the production MLX path with `esh optimize benchmark … --quick`:

- **Machine:** Apple M1 Pro · 32 GB · macOS 26.5.1
- **Model:** `mlx-community/Qwen2.5-0.5B-Instruct-4bit` (MLX, 4-bit)
- **Scenario:** chat · ~512 ctx · greedy (temp 0, seed 42)

| Strategy | decode | TTFT | peak mem | quality proxy | verdict |
|---|---|---|---|---|---|
| `kv.raw` (fp16 KV, baseline) | 245.2 t/s | 157 ms | 291.9 MB | 1.00 | ✅ auto default |
| `kv.triattention` | 246.0 t/s | 51 ms | 288.5 MB | **0.05** | ❌ rejected — output diverged (needs calibration) |
| `kv.turbo` (TurboQuant) | — | — | — | — | ⚠️ errored on this model — no data recorded |

Raw results persisted under `~/.esh/optimization/` (one JSON per strategy×scenario, with samples).

### What the evidence decided
- `kv.triattention` was **≈0.3% faster** but its output-overlap quality proxy was **0.05** vs the
  baseline (it requires a model calibration that isn't present), so it is **rejected from `auto`
  and from `speed`** by the quality floor. This is the entire point of the gate: faster invalid
  output is a regression.
- `kv.turbo` **errored** on this 0.5B model and recorded **no** measurement — it is honestly absent,
  not defaulted on.
- Therefore, on this machine/model, **`auto` = `kv.raw` + `prompt.reuse`** (conservative), and
  `speed`/`balanced` agree. `memory` would prefer `kv.turbo` for long context *as an explicit user
  preference*, flagged as not-yet-quality-validated.

This is a small, honest v1 matrix (one machine, one small model, quick mode). Populating the full
matrix (more models, `--full`, long-context KV-compression scenarios) must run on target hardware;
the harness and persistence are in place to do it.

---

## 3. Chosen defaults / rejected candidates

- **Default (`auto`)**: full-precision KV (`kv.raw`) + prompt-cache reuse. Conservative and
  distribution-equivalent. Non-baseline KV strategies enter `auto` only with local evidence ≥ the
  quality floor (0.85 proxy) and no errors.
- **Rejected from auto (this machine/model)**: `kv.triattention` (quality 0.05 without calibration),
  `kv.turbo` (errored → no evidence). Both remain *available* to expert users and to `memory` mode
  as a stated preference.

---

## 4. Tests

11 optimization tests (suite total 182, all green): strategy/backend + runtime-version
compatibility, planner auto-without-evidence → baseline, memory-mode escalation, auto uses evidence
when quality passes, auto **rejects** evidence that fails quality, **speed still respects the
quality floor**, ExecutionProfile round-trip, profile-store keying/invalidation, harness runs
strategies through a runner and computes medians + quality proxy. Plus one real end-to-end
benchmark executed on-device (above).

---

## 5. Known limitations

- The v1 matrix is small (one Apple-Silicon class, one 0.5B model, quick mode). Larger models,
  `--full`, and long-context (16k/32k) KV-compression scenarios need on-device runs.
- The quality proxy is a token-overlap/JSON-validity signal, not perplexity/KL. Adequate to reject
  gross divergence (as it did for triattention); a KL/perplexity proxy for KV-quant is a follow-up.
- `kv.turbo`/`kv.triattention` need model calibration to be useful; the harness measures whatever
  the runtime actually produces and rejects uncalibrated/broken output rather than masking it.
- Memory metric uses the runtime-reported resident memory; peak-system-pressure sampling is a
  follow-up.

---

## 6. Next optimizer candidates (behind the same boundary)

1. **Prompt/prefix-cache measurement** — benchmark `prompt.reuse` vs `prompt.off` on the
   repeated-prefix/agent workload (build/load latency + reuse speedup).
2. **Affine KV quantization** (`affine8`/`affine4`) as additional `kv-cache` strategies with a
   KL/perplexity quality proxy for long context.
3. **Speculative decoding** — wire `spec.draft` (and evaluate MLX-Swift speculative / llama.cpp
   native methods) as a `speculative-decoding` strategy; the harness already measures acceptance
   rate.
4. **CI regression gates** — a deterministic harness-shape test in CI (already present) plus an
   opt-in real-Mac benchmark suite with meaningful (non-flaky) thresholds.

The architecture goal is met: a future technique is added by registering a strategy + benchmarking
it, without rewriting inference orchestration.
