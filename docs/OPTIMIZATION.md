# esh Optimization Architecture

esh chooses inference optimizations (KV-cache strategy, prompt cache, and — in future —
speculative decoding, affine KV, etc.) behind a single boundary, driven by **local benchmark
evidence** rather than upstream claims. This doc explains the architecture and how to extend it.

## The pipeline

```
request → model/backend resolution → OptimizationPlanner → ExecutionProfile → backend execution
```

`Sources/EshCore/Optimization/`:

| Type | Role |
|---|---|
| `OptimizationStrategy` | One optimization option, declared as data (constraints, quality flags, memory delta). |
| `OptimizationStrategyRegistry` | The registered strategies + compatibility resolution. |
| `OptimizationContext` | (backend, model, runtime version, host) a strategy is evaluated against. |
| `ExecutionProfile` | The resolved plan (selections + reasons + evidence flag). Serializable; maps to `CacheMode`. |
| `OptimizationPlanner` | Produces an `ExecutionProfile` for a request + mode, using evidence. |
| `BenchmarkHarness` / `ProductionBenchmarkRunner` | Runs strategies through the real inference path and measures. |
| `OptimizationProfileStore` | Persists raw benchmark results, keyed by machine/model/backend/runtime/schema. |

## Performance modes

- `auto` — the locally validated best configuration under the quality/stability floor. With no
  evidence, conservative known-good baselines.
- `speed` — maximize decode throughput **within the quality floor**.
- `balanced` — conservative.
- `memory` — minimize peak memory within the quality floor; may apply memory-saving KV as an
  explicit user preference for long context (flagged when not yet quality-validated).

Set with `esh performance <mode>` (persisted in `config.toml` → `[defaults] performance_mode`).

## How `auto` decides (the gate)

A non-baseline strategy is selected by `auto` only if, for this (hardware, model, backend, runtime,
workload, context bucket):

1. a local benchmark result exists,
2. it has `errorCount == 0`,
3. it clears the quality floor — `distributionEquivalent` strategies pass automatically; others
   need `qualityScore ≥ 0.85` (or a measured distribution-equivalence),
4. it wins the mode's objective (decode t/s for speed/auto/balanced; lowest peak memory for memory).

Otherwise `auto` falls back to the category **baseline** (`kv.raw`, `prompt.reuse`) and records why.
The quality floor applies to **every** mode, not just `auto`.

## Adding a new optimization strategy

1. Register an `OptimizationStrategy` in `OptimizationStrategyRegistry.builtIn` with its category,
   supported `backends`, model/runtime constraints, and honest quality/memory flags. Set
   `requiresBenchmarkBeforeAuto: true` if it can change output.
2. Teach the backend execution layer to honor it. For a KV-cache strategy, map it in
   `ExecutionProfile.cacheMode` / `BenchmarkHarness.cacheMode(for:)`. For a brand-new category,
   add a selection branch in `OptimizationPlanner.plan`.
3. Add compatibility rules if needed (backend/family/runtime) — the registry already checks
   `backends`, `modelFamilies`, and `minRuntimeVersion`.
4. Benchmark it: `esh optimize benchmark <model>` runs it through the real path and persists raw
   results. Only then can `auto` consider it.
5. Add tests (compatibility, planner behavior, harness) mirroring `Tests/EshCoreTests/OptimizationTests.swift`.

You do **not** modify inference orchestration to add a strategy — that is the point of the boundary.

## Benchmark protocol

- Runs through `ExternalInferenceService` (the production path), not toy code.
- Warmup runs (discarded) + N measured repetitions; median summary + preserved raw samples.
- Metrics: TTFT, decode t/s, peak memory, KV bytes (whatever the runtime reports; missing stays
  nil — never fabricated).
- Quality: JSON validity for structured scenarios; token-overlap vs the baseline output (same
  prompt+seed) as a semantic-regression proxy for quality-changing strategies.
- `--quick` (1 run, no warmup) / default (3 runs) / `--full` (5 runs).

## Profile persistence & invalidation

Results live on the internal state root (`<stateRoot>/optimization/*.json`), keyed by
`OptimizationProfileKey` = hardware fingerprint + model id + backend + runtime version +
optimization schema version. Changing any of these (e.g. an mlx-lm upgrade, or bumping
`OptimizationSchema.version`) yields a new key, so stale results are simply not applied — no manual
invalidation needed. `esh optimize reset <model>` clears a model's evidence.

## Reproducing a result

```bash
esh optimize benchmark <model> --full --workload coding
esh optimize compare <model>        # table of measured strategies
esh optimize plan <model> --workload coding --context 16000 --mode auto --json
```
