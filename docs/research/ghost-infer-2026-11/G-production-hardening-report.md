# Production hardening: merge-readiness report (2026-11-14)

Branch `perf/inference-hardening`, stacked on `perf/ghost-infer-learnings` (fil-technology/esh#24), which is
stacked on `feat/validated-model-catalog` (fil-technology/esh#23). Machine: M1 Pro, 32 GB, macOS 27.0, mlx 0.32.2,
mlx-lm 0.31.3, llama.cpp 8660. Raw data lives in `benchmarks/results/`; every number below comes from those files.

**Nothing in this report changes a production default.** The proposed defaults are in §7 and need your approval.

## 1. Changes (isolated commits)

| Commit | Change | Phase | Default behavior |
|---|---|---|---|
| `1f2248e` | **One live memory-safety gate for every load path.** `ModelLoadSafetyGate` + `loadRuntimeGuarded` are used at all 13 sites (serve pool, infer, chat/TUI, agent, cache tools, benchmark). The pool awaits its own evictions before the gate measures memory. | 1.1 | **Changed (safety):** heavy loads that were unguarded on the CLI/server path are now refused with a reason. Small models (< 4 GB) are unaffected. |
| `0f6b260` | **Resident KV caches are budgeted in the warm pool, with pressure-driven release.** `Metrics.residentCacheBytes` and `CacheMemoryReporting`. The pool budget is weights + caches, and idle caches are released before a whole model is evicted. On a pressure warning the pool releases caches; on critical it also evicts idle models. `esh serve` subscribes to system memory pressure. The worker's `drop-caches` operation runs between requests. | 1.2–1.4 | Inactive unless a runtime reports caches (only `live` mode does). |
| `a3f52aa` | **Crash-safe temp files.** State files go to `<tmp>/esh-mlx-state/<pid>-…`, staging to `<tmp>/esh-mlx-staging/<pid>-…`, and dead-owner entries are swept at startup. `tokens` mode writes one versioned `.kv.safetensors` sidecar instead of base64 copies. | 1.5–1.6 | **Changed (safety):** state-file location and crash cleanup. Legacy snapshot content is unchanged. |
| `6bd5d7d` | **Fix:** `--kv-bits` requests crashed on bf16 models (numpy can't take bf16 scales). Token-prefix snapshots are never restored for a different model. | 2 | **Bug fix in the default path.** |
| `62b888d` | **No double model load per one-shot MLX request** (`prepareBeforeGenerateIsRedundant`). | 4.1 | **Changed (perf):** `esh infer` skips the redundant `mlx-build-cache` process. |
| `2d78576` | **Fix:** `esh optimize benchmark` crashed on MLX/GGUF (Apple-only registry). | 4.8 | Bug fix. |
| `c658c84` | **Metrics.** GGUF server timings (prefill/decode tok/s, cached tokens, drafts), MLX prefill tok/s and draft counts, and `kvModeFallback` so the KV mode never degrades silently. | 4.5–4.7 | Additive (optional fields). |
| `f37fda6` | **Live caches matched by token content** (llama.cpp-style slot selection), not by the per-request session id, which is random in esh. | 4.2–4.3 | Only affects `live` mode. |
| `a255154` | **Exact lookup mode** (`ESH_MLX_LOOKUP_EXACT=1`, verify ≤ 2) plus `diagnose_verify_numerics.py`. | 3 | Opt-in. |
| `9a9f363` | Prefix-cache validation and divergence diagnosis tools and results. | 2 | Tests only. |
| `bbae01e` | `GET /v1/runtime`: warm-pool status over HTTP. | 4.5 | Additive endpoint. |
| `386b66e` | `esh serve` integration test and the Phase 3 matrix results. | 3, 5 | Tests only. |
| `16cb563` | **Fix:** stopping `esh serve` left an orphaned `llama-server`. The pool now has an awaited `shutdown()`. | 5 | **Bug fix in the default path.** |

## 2. Tests

| Suite | Result |
|---|---|
| Root Swift package (`swift test`) | **pass**: 544 tests in the main run, plus 102 / 73 / 43 / 8 / 4 in the other test targets. New suites: gate (5), pool accounting/pressure/shutdown (8), prepare skip (2), GGUF timings (3), state files (3) |
| macOS package (`swift test --package-path macos`), which also compiles all macOS-side changes | **pass** (191 + 20) |
| Python (`unittest discover -s Tests/Python`) | **pass** (50), including real-MLX equivalence tests (tiny models) |
| Bridge static check (pyflakes undefined names; both copies identical) | **pass** |
| Real-model prefix-cache validation (`validate_prefix_cache.py`), see §4 | Llama-3-8B **19/19**; Mistral-7B tokens/live **all pass** (legacy fails, see §4); Qwen3-0.6B: numeric near-ties only |
| `esh serve` integration (`serve_integration.py`) | pass: no errors, pool status present, no leftover processes; state files swept on next start |
| GGUF tuning through `esh serve` | pass: `--spec-type ngram-simple --draft-max 16` reached llama-server; correct output |
| Live speech smoke | **not run here** (the internal-disk swap guard needs ≥ 8 GiB free); runs in CI |

Nothing failed that was left unexplained. Every non-identical output was diagnosed (§4).

## 3. Performance (equivalent configurations, greedy, medians)

**Prefix reuse**

| Measurement | Default (legacy) | `tokens` | `live` |
|---|---|---|---|
| Llama-3-8B agent session (1.6K context + 3 follow-ups), session end-to-end | 47.8 s | 19.2 s (**−60%**) | 10.2 s (**−79%**) |
| …follow-up time to first token | 7.9–8.4 s | 1.2–1.7 s | **0.39–0.60 s** |
| **`esh serve`**, Qwen3-0.6B agent session | 21.5 s | 9.8 s (−54%) | 7.9 s (**−63%**) |
| `esh serve`, two concurrent conversations | 34.9 s | 10.8 s (−69%) | 7.1 s (**−80%**) |
| Qwen3-0.6B, 8K single turn | 28.8 s, then ENOSPC | 17.1 s | **5.5 s** |
| Qwen3-0.6B, 32K single turn | killed (critical pressure) | killed | **48.1 s** |

**Speculative decoding**

| Measurement | Result |
|---|---|
| MLX lookup, Llama-3-8B, code edit (1,308 tokens) | 32.9 → **62.6 tok/s (+90%)**, end-to-end −41% |
| MLX lookup, Mistral-7B, code edit | **+62%** decode, end-to-end −33% |
| MLX lookup, chat / tool JSON / agent session / 8K | −7% … +3% |
| GGUF `ngram-simple`: Qwen2.5-0.5B / 1.5B, code edit | **+359% / +242%** |
| GGUF `ngram-simple`, Llama-3-8B-Web Q8 (doesn't copy its input) | code edit −13% |

**One-shot**

| Measurement | Result |
|---|---|
| `esh infer`, Qwen3-0.6B | ≈ 6.8 s → **3.7 s** (one fewer model load; the removed step measured 3.1 s) |

**Regressions:**
- Lookup speculation costs up to −7% when the output doesn't copy the context (chat, short JSON).
- GGUF `ngram-simple` costs −13% on a model that doesn't copy its context.
- Exact lookup mode erases the speedup (−5…+3%).
- q8_0 KV on llama.cpp is −13…−20% at short context (from the #24 study).

## 4. Correctness

- **The default (legacy) prefix path corrupts the KV cache on some templates.**
  - On Mistral-7B the string-prefix check does hit, and its untrimmed 2-token replay leaves the KV length inconsistent with the tokens on turns 3–4. Turn 4 then diverges from ground truth.
  - On Llama-3 and Qwen3 the same check never hits, so every turn is re-prefilled.
  - `tokens` and `live` are token-exact: the KV length equals reused + prefilled + generated on every turn of every model tested.
- **Prefix reuse vs full recompute:**
  - **Byte-identical** on Llama-3-8B (all 4 turns, all scenarios) and Mistral-7B.
  - On Qwen3-0.6B (bf16) turns 3–4 differ. The diagnosis: the reference's top-2 logit margin at the divergence is 0.25, while incrementally built and recomputed KV differ by up to 0.55 in logits. That's numerical noise flipping a near-tie, not corruption.
  - llama.cpp's prompt cache has the same property.
- **Lookup speculation is not bit-exact greedy.**
  - MLX forwards are batch-invariant only for small batches: ≤ 4–5 tokens at short context, and ≤ 2 at 8K and 24K (Qwen3-0.6B).
  - Measured output identity vs plain greedy: Llama-3-8B and Mistral-7B 2/2 on every workload in the latest matrix (14/15 in the first study); Qwen3-0.6B code edit 0/2.
  - Exact mode (verify ≤ 2) was identical everywhere measured, but gives no speedup.
- **Sampling:** at temperature > 0 speculation steps aside (±1%, outputs identical with a fixed seed). Exact sampled acceptance is not implemented.
- **Structured output and tool calls:** JSON validity, schema and verbatim `old` text were unchanged by every variant on every model where the baseline passed.
- **Isolation and concurrency:**
  - Live caches are popped (owned) for the duration of their request. `drop-caches` and pool eviction are queued between requests, and unit tests prove an in-flight cache can't be dropped.
  - Concurrent `esh serve` requests in `live` mode produce the same outputs as serial ones.
  - In `tokens` mode, conversations sharing one runtime overwrite a single on-disk snapshot, so concurrency changes the reuse points. Outputs stay correct but aren't stable across schedules.

## 5. Memory behavior

- **Peak RSS of `esh serve`** (Qwen3-0.6B session): legacy **4.95 GB** → `tokens` 1.48 GB → `live` 1.25 GB. The legacy figure is base64 encoding of the whole KV, twice per turn.
- **Resident session caches (`live`):**
  - 0.17–0.25 GB per session at about 1.7K tokens, roughly 128 KB per token at 8B.
  - Capped by `ESH_MLX_LIVE_PREFIX_MAX_BYTES` (default min(25% of RAM, 8 GiB)) and by slots (default 2).
  - Not retained under critical pressure.
  - Reported to the pool and visible at `/v1/runtime`.
- **Internal disk:**
  - The legacy snapshot filled the internal disk at 8K context; the disk guard now skips such snapshots.
  - `tokens` writes 1.1× the KV per turn (was about 3.8×).
  - Crash leftovers are swept on the next start.
- **MoE (Qwen3-30B-A3B):** never run. The gate refused it on every attempt (needs about 23 GB; 7–20 GB available with ≤ 4.8 GB swap headroom). That is the intended behavior on this machine today.

## 6. Remaining risks

1. **MoE is unmeasured.** It needs the machine with more free memory and disk; the command is in F-roadmap P1.1. Speculation may lose on MoE (Ghost Infer disables it there). The controller backs off, but this isn't verified.
2. **The pressure path** is tested with injected events only. The system-wide `memory_pressure -S` simulation was not used because it affects every app.
3. **`live` mode retains KV between requests.** It is budgeted and pressure-released, but a pool budget computed from estimates can still be optimistic for very large contexts. The live memory gate covers new loads, not KV growth inside an already-loaded runtime.
4. **`tokens` mode shares one snapshot per runtime.** Under heavy multi-conversation load it misses more often (correct, just slower). Per-conversation sidecars would fix that.
5. **Speculation output is not bit-exact** (§4). Fine for agents; not for workflows that require byte-reproducibility.
6. Not re-run on this branch: GGUF `ngram-simple` on a model that copies context at 7B+ (only small models measured) and the CI live speech smoke.

## 7. Recommended defaults (need approval; not applied)

| Setting | Recommendation | Why |
|---|---|---|
| `ESH_MLX_PREFIX_CACHE=tokens` | **Make default** | It fixes a demonstrated corruption (Mistral) and a never-hits bug (Llama-3/Qwen3). Token-exact, byte-identical on two 7–8B models, −60% agent sessions, ~4× lower peak memory than legacy. |
| `ESH_MLX_PREFIX_CACHE=live` | **Default only when the MLX worker is persistent (`esh serve`)**, after one soak with real Ashex sessions | Fastest (−63…−80%) and lowest memory. Accounting, pressure release, isolation and shutdown are now implemented and tested. |
| `ESH_MLX_PERSISTENT=1` | Recommend with `live` | Required for `live`; already measured 13× faster warm in earlier work. |
| One-shot prepare skip, load gate, temp-file safety, disk guard, the three bug fixes | **Merge as is** (already default) | Safety and correctness. |
| MLX lookup speculation | **Keep opt-in**; enable automatically only for the `code`/`agentrun` intents after an MoE measurement | +62…+90% on edits, −7% worst case elsewhere; not bit-exact. |
| GGUF `ngram-simple` | **Keep opt-in**; candidate for intent-gated auto | Large wins on copy-heavy output, −13% when the model doesn't copy. |
| Exact lookup mode, `ngram-mod`/`ngram-map-k`, q8_0 KV | **Keep experimental / don't recommend** | No gain, inflated by cross-request state or crashes upstream, or slower. |

## 8. Merge recommendation

- **Ready to merge** (tested, safe, compatible): `1f2248e`, `a3f52aa`, `6bd5d7d`, `62b888d`, `2d78576`, `c658c84`, `bbae01e`, `16cb563`, plus the cache-accounting machinery `0f6b260` (inert unless `live` is on).
- **Merge as opt-in** (flags default off): `f37fda6`, `a255154`, and #24's speculation and GGUF tuning.
- **Defaults to flip after your approval:** `tokens` now; `live` for the persistent worker after a soak.
