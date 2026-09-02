# esh 2.1 — Architecture

Grounded in an audit of the stable `v2.0.0` code (file:line seams below). The theme: **esh 2.0 already
computes most of an execution plan and already has a generic warm pool — but the pieces are decoupled,
evidence is fragmented across three stores, and speech lives entirely outside the system.** 2.1
*connects and unifies* rather than rebuilds.

## Current state (what exists in 2.0)
- **SchedulerService** (`Services/SchedulerService.swift`) already returns a `SchedulerDecision`
  carrying `selectedModelID + backend + performanceMode + full ExecutionProfile + fitClass +
  estimatedPeakMemoryGB + evidenceBacked + candidatesConsidered + rationale[]`. It consumes
  `CapabilityRequest`, installs, `HostMachineProfile`, `ModelFitService` estimates, and Model Benchmark
  Lab evidence. It takes `warmModelIDs`/`otherResidentGB` **as parameters** but never calls the pool.
- **OptimizationPlanner** (`Optimization/OptimizationPlanner.swift`) picks per-category strategies
  (`kv-cache`, `prompt-cache`) from the `OptimizationStrategyRegistry` (strategies are **data**, with a
  `requiresBenchmarkBeforeAuto` gate). `spec.draft` exists as a declared-but-inert placeholder
  (`backends: []`).
- **RuntimeLifecycleManager** (`Runtime/RuntimeLifecycleManager.swift`, an `actor`): multi-resident
  (cap 3), states (unloaded→warm→active→idle…), LRU idle eviction, memory-pressure reclaim, bounded
  concurrency + interactive/background priority, crash recovery, and a **backend-agnostic loader**.
  MLX (`MLXPersistentRuntime`) and GGUF (`LlamaServerRuntime`) conform to `ResidencyReporting`.
- **Evidence is fragmented across three stores:** Model Benchmark Lab dataset
  (`~/.esh/benchmarks/…`, read by the Scheduler), `OptimizationProfileStore` (`~/.esh/optimization/…`,
  read by the Planner), and a legacy `FileBenchmarkStore`/`BenchmarkService`.
- **Model knowledge is split:** hard-coded `RecommendedModelRegistry` (estimates), `ModelFitService`
  (pure estimate math), and Lab evidence (measured) are joined only inside `Scheduler.score()`.
- **Speech is outside everything:** `AudioSpeechGenerator` (TTS) builds a fresh synthesizer per call;
  `SpeechToTextService` (STT) is a per-call bridge command. Neither uses the pool, scheduler, or
  evidence. A `ttsReserveGB` hook exists but is unused.

## Target 2.1 architecture

### 1. `ExecutionPlan` as a first-class object
Promote today's `SchedulerDecision`+`ExecutionProfile` into one persisted/streamed **`ExecutionPlan`**:
`model · backend · format/quant · runtime · residency intent · KV policy · prompt-cache policy ·
context policy · reasoning budget · speculative strategy · memory actions · speech lifecycle · rationale
+ evidence refs`. `ExecutionProfile` is ~80% of this already; extend it additively (new optional fields,
same `schemaVersion` discipline) so `esh.infer.response.v1` and CLI `--json` stay compatible.

### 2. ExecutionPlan Scheduler (Scheduler v2) — close the loop
The scheduler must **read live warm-pool + memory-pressure state** (`RuntimeLifecycleManager
.residentModelIDs()/status()`) and **emit resource actions** the pool executes (acquire / prewarm /
evict / reserve), instead of taking warmth as a passive parameter. It folds the OptimizationPlanner's
per-category choices into the single plan so model + backend + strategies + residency are decided
together, each with a rationale line. Every choice remains explainable → **"Why this execution plan?"**.

### 3. Unified Local Evidence Layer (M14)
Consolidate the three evidence stores behind one interface keyed by
`(model-revision, backend/runtime version, hardware class, strategy, workload)`, holding measured
latency/throughput/memory/stability/quality + **confidence + freshness + provenance**. Local evidence
overrides curated/estimated **only above a sample/confidence threshold** and is invalidated on
model/runtime/esh/optimizer change. No external telemetry. The Scheduler and Benchmark Lab both read/
write it; the UI marks **measured-on-this-Mac vs estimated**.

### 4. Unified per-model record
One `ModelKnowledge` record that composes catalog metadata + fit **estimate** + Lab/local **measurement**
with explicit source/confidence, so "estimated vs measured" is a property of the data, not an accident of
`score()`. Feeds Model Browser, Model Fit, and the scheduler.

### 5. Speech as a first-class runtime
Introduce a **`SpeechBackend` protocol** (STT + TTS) analogous to `InferenceBackend`, and register
persistent speech workers with `RuntimeLifecycleManager` so they warm/evict/reserve alongside LLMs
(the `ttsReserveGB` hook already anticipates this). This is the structural fix behind M12/M13 — STT
measured at ~4–6 s/call today because it re-inits every request.

### 6. Extension seams to open (only where justified)
- **Backends:** `InferenceBackend`/`BackendRuntime` protocols are clean, but `BackendKind` (enum) and
  `InferenceBackendRegistry.backend(for:)` (hard-coded `switch`) are closed. Make backend resolution
  registration-driven so a new backend is data + a registered factory, not enum surgery.
- **Optimizers:** advertising a strategy is registration-only, but `OptimizationPlanner` only *plans*
  `kvCache`/`promptCache`. Add per-category planning for **speculative** and **runtime** categories so
  `spec.*` and tuning strategies can actually be selected (behind benchmark gates).
- **Speech:** add the `SpeechBackend` registry (none exists today).
- Absorb the `ExecutionProfile.cacheMode` compatibility shim so resolved strategies drive the backend
  directly instead of being mapped back onto the legacy `CacheMode` knob.

## Compatibility strategy (preserve the 2.0 baseline)
- Keep `esh.capabilities.v1`, `esh.infer.request.v1`, `esh.infer.response.v1`, `esh.prompt-cache-key.v1`
  decodable; add ExecutionPlan detail as **optional additive fields** (missing-schemaVersion defaults
  preserved). Bump a schema version only for a genuine breaking change, with a migration.
- Preserve `EshConfig` TOML keys/defaults, model storage layout (`FileModelStore`, external
  `storage.json`), OpenAI/Anthropic adapters, CLI `--json` field names, and the Web self-contained/
  no-external-host guarantee.
- If a llama.cpp bump past b8660 is adopted for EAGLE3/n-gram speculative, the changed flags
  (`--draft-max`→`--spec-draft-n-max`, new `--spec-type`) are an **internal** packaging change behind
  `LlamaServerProcess` — no external contract impact — but must be re-validated (packaged, notarized,
  no-Homebrew) exactly like rc.4/rc.6.

## What 2.1 must NOT do
- No agent semantics / autonomous loops / durable jobs / semantic memory (Ashex owns these).
- No generic plugin ecosystem for its own sake — open only the seams above, each justified.
- No remote/multi-user exposure by default (research-only, security-first).
- No behavioral change promoted to `Auto` without local benchmark + correctness/quality + stability
  evidence.
