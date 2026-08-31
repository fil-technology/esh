# esh M7 — Runtime Lifecycle / Warm Pool Report

Milestone M7 (master roadmap). Adds a production runtime-lifecycle layer so model runtimes stay warm
and reused, memory is budgeted, and the Adaptive Scheduler becomes resource-aware. Backend-agnostic
by design: the lifecycle manager sits above MLX / llama.cpp / Apple, which only provide load/unload
hooks beneath it.

## What was built

`Sources/EshCore/Runtime/`:

- **`RuntimeLifecycleManager`** (actor) — the warm pool:
  - **Loaded-model registry** keyed by install id; state machine
    `unloaded → loading → warm → active → idle → unloading / failed`.
  - **Load deduplication** — concurrent requests for the same model share one load (`loadingTasks`).
  - **Unified-memory budget** — `usableBudgetGB` (host RAM − safety reserve); a **configurable
    safety reserve** and a **TTS reserve** for text+speech coexistence.
  - **Eviction** — idle-timeout eviction (`evictIdle`), memory-pressure reclaim
    (`reclaimForPressure`), and evict-idle-LRU-to-fit when loading a new model; **over-budget
    refusal** when nothing is evictable (`RuntimeLifecycleError.overBudget`).
  - **Bounded concurrency** — `maxConcurrentRequests` with an **interactive-over-background
    priority** admission queue.
  - **Cancellation** — a waiting request that is cancelled throws `.cancelled` and frees its slot.
  - **Prewarm**, safe **unload/reload**, and **`RuntimePoolStatus`** (residents, states, estimated
    vs measured memory, active requests, budget) for doctor/status/scheduler.
- **`ExternalInferenceService`** gains an optional warm pool: when present it `acquire`s/`release`s
  from the pool (warm reuse) instead of load+unload per request. **`esh serve` now runs with a
  shared pool**, so models stay warm across HTTP requests.
- **Adaptive Scheduler resource-awareness** — `SchedulerService.decide(… warmModelIDs:)` gives a
  warm model a small, bounded bonus so it wins *close* calls (a materially better cold model still
  wins), and records "already warm — answers immediately" in the rationale. This realizes the
  intended reasoning: *"Model A scores 3% better, but Model B is already warm."*

## Honest scope / measured vs estimated

- **Memory is honest about provenance.** The pool budgets on an **estimate** (from install weight
  bytes × overhead) before a run and records the **measured** resident memory (from the generation
  `Metrics`) after. `RuntimePoolStatus`/`ResidentModelInfo` expose both; estimates are never
  presented as measurements.
- **MLX deep residency is a documented follow-up.** Today MLX generation runs through a per-call
  bridge subprocess, so keeping the `BackendRuntime` handle warm avoids re-instantiating the wrapper
  but does not yet keep model weights resident across calls (that needs a persistent bridge process).
  The lifecycle abstraction is built to host that change without touching the scheduler/inference
  layers. llama.cpp and future in-process backends benefit immediately from handle reuse.
- **Scheduler warm input** is wired through `decide(…warmModelIDs:)`; the server (where the pool is
  long-lived) can pass `manager.residentModelIDs()`. One-shot CLI scheduling has no resident pool
  (fresh process), which is reported honestly (empty warm set).

## Tests (deterministic)

12 lifecycle/scheduler tests (suite total **228**, green):
concurrent-load dedup, cancellation of a waiting request, idle eviction (fresh kept / stale evicted
with an injected clock), over-budget refusal, evict-idle-to-fit-within-budget, TTS-reserve reduces
budget (text+speech coexistence), failed-load recovery on retry, unload/reload increments load
count, status reporting, warm-model preference on close calls, and a much-better-cold-model still
beating a tiny-warm-one.

## Known limitations / next

- Persistent MLX bridge for true weight-residency warmth.
- A running-server `esh runtime status` surface (the pool is per-process; exposing it needs a small
  server endpoint since a one-shot CLI can't see a running server's pool).
- Real-hardware stress test of multi-model residency + pressure eviction under load (deferred; needs
  adequate disk to hold multiple models — the dev machine is storage-constrained).
