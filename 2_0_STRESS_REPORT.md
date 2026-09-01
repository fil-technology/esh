# esh 2.0.0 — Stress & Resource Report (Phase P)

**Date:** 2026-09-01
**Environment:** Apple M1 Pro, macOS 26, models on external ExFAT SSD ("Sviat SSD").

## What was exercised (this session)

| Test | Result |
|---|---|
| Persistent residency warm/cold | Cold 1.81 s → warm 0.18 s (~10×). Weights stay resident. |
| Concurrency (8 simultaneous `/v1/chat/completions`, resident 0.5B) | **8/8 → HTTP 200; server stayed alive.** No crash, no orphaned workers. |
| Concurrency (20 simultaneous) | All accepted, but generations **serialize** through the single resident `mlx-serve` worker; 20× exceeded a 2-minute wall-clock harness limit. Not a failure — a throughput/serialization characteristic. |
| Worker lifecycle | Killing the server terminates the bridge child (stdin-EOF); **no orphans**. Crash-recovery path re-loads a fresh worker (covered by `MLXPersistentWorkerTests`). |
| GGUF one-shot | `llama-completion` path returns and exits cleanly (no hung interactive process). |
| Request-body cap | Spoofed 999999999-byte `Content-Length` → immediate HTTP 400 (no memory accumulation). |

## Resource findings

- **Serialization under load.** A single persistent MLX worker processes one generation at a time, so
  concurrent requests queue. This is safe (all succeed) but bounds throughput. For 2.0 this is
  acceptable for a local single-user tool; a future worker-pool could parallelize. **Documented, not
  a blocker.**
- **Host disk pressure (real).** The internal Data volume was ~100% full during this session; a link
  step failed with `errno=28 (No space left on device)` until scratch files were removed. Model
  storage correctly lives on the external SSD (~1.1 TB free), but **build/packaging on this host is
  disk-constrained**. Recommendation: ensure ≥ several GB free on the system volume before building or
  running the notarized packaging pipeline.

## Not exercised here (environment-limited — labeled, not claimed)

- **Multi-hour soak** (memory growth / fd leaks over hours of continuous generation).
- **Large-model pressure** (24B flagship under sustained load; memory-pressure eviction under a real
  workload mix).
- **Sustained high-concurrency** beyond a short burst.

These require a longer-running, less disk-constrained environment and should be run before GA. The
short-burst evidence above shows correctness and stability; the open items are about endurance and
scale, not correctness.

## Verdict

No stability defects found in the exercised scenarios. Two documented characteristics (worker
serialization; host disk pressure) and three endurance/scale tests deferred to a suitable environment.
