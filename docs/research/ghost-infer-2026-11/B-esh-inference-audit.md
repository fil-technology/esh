# esh local text-inference audit (2026-11-14)

This is the baseline for the Ghost Infer study. It was taken on branch `perf/ghost-infer-learnings`, cut from
`feat/validated-model-catalog` (esh VERSION 2.4.0-rc.36), on an M1 Pro with 32 GB of RAM. The audit was read-only,
except where a measurement is cited; measurements come from [D-benchmark-report.md](D-benchmark-report.md).

## 1. Backends and pinned versions

| Backend | How esh drives it | Pin |
|---|---|---|
| **MLX text** | Swift starts a Python subprocess, `Tools/mlx_vlm_bridge.py`, which calls `mlx_lm.stream_generate`. **One-shot** mode is `MLXRuntime`: a `mlx-build-cache` process and then a `mlx-generate` process for each request. **Persistent** mode is `MLXPersistentRuntime` plus `MLXWorkerProcess`: an `mlx-serve` worker over NDJSON stdio, used only when `ESH_MLX_PERSISTENT=1`. | `Tools/python-requirements.txt`: `mlx>=0.31.2`, `mlx-lm>=0.31.3`, `mlx-vlm==0.5.0`. The active managed venv has mlx 0.32.2, mlx-lm 0.31.3 and **no mlx_vlm**, so TurboQuant KV silently degrades to raw. |
| mlx-swift / mlx-swift-lm | Vision (`EshVision`) and image generation only; not used for text. | mlx-swift 0.32.3, mlx-swift-lm 3.32.3 |
| **llama.cpp server** (macOS CLI) | A persistent `llama-server` subprocess per model (`macos/.../GGUF/LlamaServerProcess.swift`), streaming SSE from `/v1/chat/completions`. | `scripts/build-llama.sh` tag **b8660**; the Homebrew build is also 8660 |
| llama.cpp embedded | In-process C API via `esh_llama.xcframework` (`Sources/EshLlamaCpp`). | commit `4a89937` |
| TurboQuant / TriAttention | Custom KV transforms in the bridge (`_apply_kv_mode`, `Tools/triattention_runtime.py`). | needs mlx-vlm 0.5.0 |

## 2. Lifecycle, scheduling and guarding

- **`RuntimeLifecycleManager`** (`Sources/EshCore/Runtime/RuntimeLifecycleManager.swift`) is the warm pool.
  - LRU, at most 3 resident models, 300 s idle timeout, at most 2 concurrent.
  - Budget is total memory − 3 GB; each model is estimated at its size × 1.3.
  - It is used by `esh serve`/`web`. `esh infer` builds **no pool**, so one-shot MLX loads the model twice per request.
- **`MemorySafetyPreflight`** (`Sources/EshCore/Runtime/MemorySafetyPreflight.swift`) is the live load gate (available memory, pressure, swap headroom on the internal disk). Only the SDK facade, `EshRuntime.loadRuntime`, calls it; the CLI/serve path relies on the pool estimate.
  - The study's benchmark harness ports `evaluate` and adds a kill-on-low-memory watchdog (§5).
- **`ModelFitService`** handles the fit check before download; **`SchedulerService` + `OptimizationPlanner`** choose the model and profile.

## 3. What each backend exposes (before this study)

| Knob | MLX bridge | llama-server (esh args) | Upstream support |
|---|---|---|---|
| Speculative decoding | none | none (`OptimizationStrategyRegistry`: "not yet wired") | mlx-lm: draft model only. llama.cpp b8660: draft model plus `--spec-type ngram-simple / ngram-map-k / ngram-map-k4v / ngram-mod / ngram-cache` |
| KV quantization | uniform `kv_bits` / TurboQuant / TriAttention via `config` | **not passed** | llama.cpp `-ctk/-ctv q8_0/q4_0` |
| Flash attention | MLX SDPA (built in) | upstream default `auto` | — |
| Prefix reuse | state-file snapshot plus **string**-prefix check (see §4) | `cache_prompt: true`, a single slot | llama.cpp `--cache-reuse`, `--slot-save-path` |
| Context size | no `max_kv_size` | `-c 8192` hard-coded (`config.toml context_size` is parsed but not wired) | — |
| Prefill chunk / wired limit / cache limit | mlx-lm defaults; no `set_cache_limit` | `-b/-ub` defaults | — |
| Structured output | unavailable on MLX | `json_schema` / `grammar` | — |
| Metrics | TTFT, decode tok/s, peak Metal, cacheHit | TTFT only (`timings` not parsed) | llama-server `timings` |

## 4. Defects found during this study

1. **The MLX prefix cache never hits on current templates.** It was measured with Llama-3-8B-Instruct and checked against the Qwen3 template.
   - The legacy reuse needs the re-rendered previous conversation (`add_generation_prompt=False`) to be a string prefix of the new prompt.
   - Llama-3's template appends `<|start_header_id|>assistant<|end_header_id|>` even with `add_generation_prompt=False`.
   - Qwen3 keeps `<think>\n\n</think>` in the latest assistant turn but strips it from history turns.
   - Result: `cacheHit=false` on every agent turn, so the whole history is prefilled each turn (time to first token grows linearly with the session).
2. **The legacy hit path can corrupt the KV cache.** On a hit it replays from `len(previous)-2`, but it never trims the restored cache, whose offset is prompt + generated tokens. Where the string check does pass (for example ChatML without thinking), the overlap tokens can sit in the cache twice.
3. **The per-turn snapshot tax.** Every request serializes the whole KV twice into the JSON state file, once as base64 numpy tensors and once as base64 safetensors, even in the persistent worker that already holds the cache. The next turn deserializes it.
   - At Llama-3-8B (≈128 KB of KV per token), about 700 context tokens cost ≈1.2 s after the last token.
   - The cost scales linearly with context.
4. **Snapshots go to the internal (swap) volume, so long contexts are unsafe.** `MLXRuntime`/`MLXPersistentRuntime` put the state file in `temporaryDirectory`, and the safetensors staging file also lands in the temp dir.
   - Measured with 3–5 GB free: an 8K-token session failed with ENOSPC, and a 32K one drove memory pressure critical.
   - A worker killed mid-save leaked a 3.1 GB staging file.
   - **Fixed** (`4c6813c`): a disk-budget guard skips the snapshot whenever it would breach the 3 GB swap floor.
5. **`EshManagedPythonHost.run` could hang forever.** It used `Process.waitUntilExit()` from a detached task. Fixed on the catalog branch (`cef4e71`) with a termination latch.
6. **`esh optimize benchmark` uses the Apple-only default registry**, so MLX and GGUF hit `preconditionFailure`. Not fixed here; it is on the roadmap.
7. The embedded llama runtime never clears KV between `generate` calls (latent).

## 5. Benchmark infrastructure

Existing harnesses (`benchmarks/bench_mlx_lm.py`, `quality/`, `run_qwen3next_iq2xs.sh`) drive **raw** mlx_lm / llama-cli, outside esh's request path. `esh benchmark lab` goes through `ExternalInferenceService` without a pool.

This study adds **`benchmarks/esh_infer_bench.py`**:
- It drives esh's **production** paths: the `mlx-serve` worker protocol (esh's prompt rendering, state file and KV modes) and `llama-server` with esh's exact arguments.
- It is gated by a port of `MemorySafetyPreflight.evaluate` and a 0.5 s watchdog that kills the engine on critical pressure or low available memory.
- Workloads are Ashex-shaped, scored for correctness (code-edit rename completeness, tool-call JSON validity, verbatim `old` text), and long-context.

## 6. Opportunities (input to the decision, doc C)

| Opportunity | Evidence | Kind |
|---|---|---|
| Prompt-lookup speculation for agent edits (MLX) | Ghost Infer `lookup.rs`; mlx-lm has no n-gram mode | new implementation (done, flagged) |
| Expose llama.cpp n-gram speculation / KV types | upstream b8660 has them; esh passes neither | configuration (measured, doc D) |
| Token-exact prefix reuse; no per-turn snapshot in the persistent worker | defects 1–3 | bug fix plus runtime change (done, flagged) |
| Saved system-prompt "openings" across sessions (Ghost Infer) | Ashex agent/subagent switches | roadmap |
| MemorySafetyPreflight on the serve/CLI pool path | §2 | roadmap |
| Parse llama-server `timings` (prefill/decode tok/s) | §3 | small, roadmap |
