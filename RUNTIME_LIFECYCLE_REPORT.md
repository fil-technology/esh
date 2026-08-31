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

## Real-runtime validation (measured, not mocked)

Measured through `esh serve` on this M1 Pro with `mlx-community/Qwen2.5-0.5B-Instruct-4bit`, three
identical `/v1/chat/completions` requests in one long-lived server process:

| Request | Wall time |
|---|---|
| 1 (cold) | 3.91 s |
| 2 | 3.08 s |
| 3 | 3.10 s |

`pgrep mlx_vlm_bridge` between requests shows **no** persistent bridge process. Source confirms
`MLXRuntime.generate` spawns a **fresh Python subprocess per call** that loads the model from disk
and exits. **Conclusion: MLX is NOT truly warm today** — the ~0.8 s request-2 gain is OS file-cache /
Python-import warming, not weight residency; each request still reloads the model (~3 s).

## Truthful residency state (the important correctness fix)

Because of the above, the pool does **not** claim true warmth for MLX. A `RuntimeResidency` is
tracked and exposed per resident model:
- **`weights-resident`** — weights stay in memory across requests (true warmth).
- **`handle-cached`** — only a lightweight runtime handle is cached; the backend reloads weights per
  call. **This is the honest state for today's MLX and llama.cpp backends** (both spawn a subprocess
  per generate), and it is what `RuntimePoolStatus` reports (verified by test).

So `warm` in the state machine means "a handle is available"; `residency` tells the caller whether
that is real weight residency. The Scheduler/UI must read `residency`, not assume `warm` = resident.

- **Memory is honest about provenance.** The pool budgets on an **estimate** (install weight bytes ×
  overhead) before a run and records **measured** resident memory (from the generation `Metrics`)
  after; `RuntimePoolStatus` exposes both. Estimates are never presented as measurements.
- **True weight residency is a tracked follow-up.** It requires a **persistent MLX bridge** (load the
  model once in a long-lived process, serve many generate requests, keep weights in memory). That is
  a Python-protocol + process-lifecycle change with real risk (stream framing, deadlocks, zombie
  processes); per the milestone guidance it is not chased at the cost of destabilizing the release.
  The lifecycle abstraction already models it via `RuntimeResidency.weightsResident`, so a persistent
  backend can declare true residency without touching the scheduler/inference layers.
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
