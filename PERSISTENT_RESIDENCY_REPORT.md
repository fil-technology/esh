# Persistent MLX Runtime Residency — Report

Implements true weights-resident MLX execution via a long-lived worker process, owned by the existing
`RuntimeLifecycleManager` (no parallel runtime manager). Branch `codex/persistent-mlx-worker`.

## The problem (from M7)

The MLX runtime spawned a fresh Python process per `generate`, reloading model weights every request.
"Warm" only meant a Swift handle was cached — `RuntimeResidency.handleCached`, not true residency.

## Approach chosen (after audit)

A persistent worker mode for **esh's own bridge** (`mlx-serve`), not `mlx_lm.server`. Rationale: the
bridge carries esh's optimization differentiators (TurboQuant / triattention KV, prompt-cache
snapshotting); `mlx_lm.server` is vanilla and would drop them. The worker loads the model once and
serves many requests over a newline-delimited JSON protocol. Backend/protocol detail stays hidden
behind `BackendRuntime`.

```
esh → RuntimeLifecycleManager → MLXPersistentRuntime → MLXWorkerProcess ⇄ python mlx-serve (weights resident)
```

- `mlx-serve` (Python): loads once, then loops on stdin: `init` / `generate` / `cancel` / `ping` /
  `shutdown`; emits `ready` / `token` / `done` / `error` / `pong`. Generation core is shared verbatim
  with the one-shot path (`_generate_with_loaded_model`), so behavior is identical.
- `MLXWorkerProcess` (Swift): owns the process, demuxes events per request id, cancellation, crash
  detection, startup timeout, robust line reader.
- `MLXPersistentRuntime`: a `BackendRuntime` reporting truthful residency via `ResidencyReporting`.
- `MLXBackend(persistent:)` returns it; the warm pool's loader builds it, gated by
  `ESH_MLX_PERSISTENT` until we make it default.

## Benchmark — persistent vs one-shot (`esh serve`, qwen2.5-0.5b-instruct-4bit, 16 tok)

| | request 1 (cold) | requests 2–5 (warm) | resident worker |
|---|---|---|---|
| **Persistent** (`ESH_MLX_PERSISTENT=1`) | 2.45s | **0.21–0.26s** | pid stable, 536 MB RSS |
| **One-shot** (reload per request) | 3.27s | 3.25–3.36s (reload every time) | none |

- **~13× faster** warm (0.24s vs 3.28s). Even cold persistent beats one-shot because the Python+MLX
  import cost is paid once, not per request.
- The saving is dominated by model **load + interpreter import**, which scale with model size — so the
  advantage grows sharply for large models (seconds→tens-of-seconds saved per request), while for this
  tiny model it is already decisive.
- Memory: one resident model costs its weight footprint continuously (0.5b ≈ 0.5 GB); the lifecycle
  manager's unified-memory budget + idle/pressure eviction bound this.

## Requirement coverage

| Requirement | Status | Evidence |
|---|---|---|
| Persistent process, weights resident | ✅ | worker pid stable across requests; warm 0.24s |
| Streaming | ✅ | per-token `token` events demuxed by id |
| Cancellation | ✅ | `cancel` op + `should_cancel` poll; stream teardown sends cancel |
| Crash detection/restart | ✅ verified | killed worker (SIGKILL) → next request auto-reloaded a fresh worker (new pid) and succeeded; `ensureResident` drops an unhealthy idle runtime and reloads |
| Graceful unload | ✅ | `shutdown` op → stdin close → worker exits; then force-terminate fallback |
| Lifecycle-manager ownership (no parallel manager) | ✅ | loader builds it; `unload()`/eviction terminate it |
| Model switching / idle / pressure eviction / bounded concurrency | ✅ (reused M7) | manager budget + LRU + admit control unchanged |
| No orphan workers | ✅ | killing serve closes stdin → EOF → worker exits (verified: 0 orphans) |
| Clean shutdown | ✅ | `RuntimeLifecycleManager.unloadAll()` |
| Truthful residency + health via status/ExecutionProfile | ✅ | `ResidencyReporting` → `status().residents[].residency`; `ExecutionProfile.residency` |
| Scheduler integration | ✅ (via warm-awareness) | scheduler already rewards warm models; residency is now truthfully weights-resident when enabled |

## Default vs opt-in

Persistent residency **materially improves latency** at acceptable, budget-bounded memory cost. It is
kept **opt-in (`ESH_MLX_PERSISTENT`)** for this first release because it is new subprocess code on the
hot path; recommendation is to flip it default-on for `esh serve`/chat after a stability soak
(crash-recovery and long-run leak testing). Truthful residency reporting is correct in both modes, so
nothing is misrepresented while it is opt-in.

## Not yet done / follow-ups

- Make it the default after soak; add crash-recovery and 24h-leak soak tests to CI (gated).
- llama.cpp analogous audit: `llama-cli` is also per-request; a persistent `llama-server` path is the
  analogous option (separate follow-up).
- Surface residency in `esh doctor` live pool view (doctor is currently one-shot; the data already
  lives truthfully in `RuntimePoolStatus`).
- In-memory KV residency keyed by session (today cross-turn warmth still uses the disk state file; the
  weights are resident, the KV cache is reloaded from the snapshot).
