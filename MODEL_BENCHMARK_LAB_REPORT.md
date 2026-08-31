# Model Benchmark Lab — Report

A real, esh-native benchmark lab that measures installed models through esh's own inference path (not
a duplicate runtime) and produces **versioned, machine-readable, provenance-stamped** evidence that
feeds `esh model recommended`. Branch `codex/benchmark-lab`.

## What it does

`esh benchmark lab [--all | <model-id> …] [--json]`:
- Runs a small **deterministic** quality probe suite (math / instruction-following / structured-output
  / coding / general) with checkable answers — nothing is model-judged or fabricated.
- Measures performance from the **real runtime metrics** (TTFT, decode tok/s, peak memory) reported by
  each generation, plus model disk size.
- Records **provenance**: date, esh version, hardware, runtime version, quantization, suite version.
- Stores a **versioned** `ModelBenchmarkDataset` (`~/.esh/benchmarks/model-benchmark-dataset.json`).
- Computes **profile leaders** (Fast / Low Memory / Reasoning / Coding / Maximum Quality) from the
  local evidence.

The evidence feeds `esh model recommended --explain`: models with lab evidence are marked
**“★ measured on your Mac”** with their measured quality, so **local measured evidence overrides
curated estimates** when present.

## Storage / hardware

Model assets live on the external SSD (`/Volumes/Sviat SSD`, 1.27 TB free) via `esh storage set`, which
also surfaced and fixed a real bug: free-space reporting returned 0 on non-APFS (ExFAT) volumes
(`volumeAvailableCapacityForImportantUsage` is APFS-only) — now falls back correctly (1.27 TB reported).

Host: Apple M1 Pro / 32 GB.

## Candidate set (Model-Fit-runnable, carefully selected — not "download everything")

| alias | size | role | status |
|---|---|---|---|
| qwen2.5-0.5b-4bit | 0.29 GB | tiny baseline | benchmarked |
| llama-3.2-3b-4bit | 1.82 GB | small, tool-calling | benchmarked |
| deepseek-r1-qwen-7b-4bit | ~4.3 GB | reasoning | downloading |
| qwen3.5-9b-mlx-4bit | 5.98 GB | general/coding workhorse | **incompatible with current runtime (see finding)** |

## Findings

### Measured evidence (representative; a clean quiet-system re-run supersedes contaminated numbers)

| model | TTFT | decode tok/s | peak mem | quality |
|---|---|---|---|---|
| qwen2.5-0.5b | ~44 ms | ~279 | 292 MB | 4/5 (fails 17×23) |
| llama-3.2-3b | ~103 ms | ~103 | 1888 MB | 5/5 |

The 0.5B is ~2.7× faster decode and ~6× lighter but fails harder reasoning; the 3B is the quality
leader. (A batch run taken *while a large download was saturating disk I/O* showed depressed tok/s —
benchmark hygiene: perf must be measured on a quiet system; the lab records provenance so such runs are
identifiable and re-runnable.)

### Real bugs surfaced by the lab

1. **Free-space reporting on ExFAT** returned 0 → fixed (would have blocked all downloads/Model Fit).
2. **`prompt_cache[0].offset` crash** on newer mlx-lm cache types (`ArraysCache` has no `.offset`) →
   fixed with a safe `_cache_offset` fallback.
3. **qwen3.5-9b is not runnable on the installed runtime.** After the cache fix it fails deeper inside
   mlx-lm (`create_attention_mask() missing 'return_array'/'window_size'`) — a runtime **mlx-lm version
   incompatibility**: the qwen3.5 architecture needs a newer mlx-lm than the pinned runtime provides.
   The curated catalog lists it as *recommended*, but **measured evidence shows it cannot run** — a
   direct demonstration of why local measured evidence must override curated claims. Not "fixed" by
   force-upgrading mlx-lm mid-session (stability risk to other models); recorded truthfully as
   unstable, tracked as a runtime-dependency follow-up.

## Remaining

- Clean quiet-system perf re-run once downloads finish; add the 7B reasoning model.
- Resolve the runtime mlx-lm version for qwen3.5-class models (dependency bump + regression check).
- Deeper quality axes (long-context retrieval, tool-calling reliability) and larger models (14B/32B)
  now that the SSD has room.
- Feed lab evidence into onboarding and the Scheduler (recommendations wired; scheduler is the next
  milestone).
