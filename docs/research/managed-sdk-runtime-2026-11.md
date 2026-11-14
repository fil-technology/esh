# Unifying SDK and server runtime management (2026-11-14)

Branch `feat/managed-sdk-runtime`, from `main` at `998a00d`. Machine: M1 Pro, 32 GB, macOS. Integration guide for Studio: [docs/integration/esh-sdk-managed-runtime.md](../integration/esh-sdk-managed-runtime.md).

## 1. Embedded llama.cpp (GGUF) resource ownership audit

### 1.1 What owns what (before the fix)

| Resource | Allocated in | Owner | Freed by |
|---|---|---|---|
| llama model (weights, mmap + Metal buffers) | `LlamaContext.make` → `llama_model_load_from_file` | `LlamaContext` actor | `unload()` only |
| llama context (KV buffer of `n_ctx`, compute buffers) | `llama_init_from_model` | `LlamaContext` actor | `unload()` only |
| sampler chain | per `generate` | local | `defer llama_sampler_free` ✅ |
| prompt/role C strings | `formatPrompt` (`strdup`) | local | `defer free` ✅ |
| ggml backend | `llama_backend_init()` on **every** load | process | never (process-global; harmless but repeated) |

There was **no `deinit`** anywhere in `EshLlamaCpp`, and **`EshRuntime.generate`/`stream` never called `unload()`**. So:

1. **Every facade call leaked one model + context.** Each call ran `backend.loadRuntime` → new `LlamaContext`, and nothing released it.
2. **A dropped runtime leaked.** A host that forgot `unload()`, or a cancelled task, kept the native memory forever.
3. **A reused runtime was incorrect.** `generate` decoded the full prompt on top of the previous request's KV without clearing it. Turn 2 produced different output; once the positions filled `n_ctx` the decode failed ("failed to find a memory slot").
4. **Cancellation only between tokens.** The whole prompt was decoded in one `llama_decode`, which also fails for prompts larger than `n_batch`.
5. **The decode-rate metric was wrong.** `tokensPerSecond` divided generated tokens by the whole call including prefill, under-reporting decode several-fold on long prompts.

Model switching and macOS vs iOS share the same code: the backend is identical on both, so all of the above applied to iOS apps too.

### 1.2 Runtime verification (real model, ≥30 sequential turns)

`Tests/EshLlamaCppTests/EmbeddedGGUFMemoryTests.swift`, Qwen2.5-0.5B-Instruct Q4_K_M, measured as the process **physical footprint** (`task_vm_info.phys_footprint`, what Jetsam and Xcode's gauge charge an app, Metal buffers included) after every turn. Raw data: `benchmarks/results/gguf-memory-prefix.jsonl` (before) and `gguf-memory-postfix.jsonl` (after).

| Scenario (30 turns) | Before: footprint after turn 1 → 10 → 20 → 30 | After |
|---|---|---|
| Public facade `EshRuntime.generate`, pinned GGUF | 139 → 688 → 1,290 → **1,896 MB** (+~60 MB per call, linear) | 50 → 83 → 85 → **85 MB** (flat after warm-up) |
| Runtime dropped without `unload()` | 121 → 672 → 1,271 → **1,870 MB** (+~60 MB per drop) | 89 → 89 → 89 → **89 MB** |
| Explicit load → generate → `unload()` | flat (+0.4 MB over the second half) | flat (0.0 MB) |
| One runtime reused for 30 turns | **19 of 26 turns differ** from a fresh context; **decode failure at turn 27** | **30/30 identical** to a fresh context; +0.1 MB |
| Cancel mid-stream, then reuse | next turn **differs** from a fresh context | identical |

How the three effects were told apart:
- **Genuine leak:** a linear climb of about one context per call that never comes back (facade and drop rows, before). Explicit `unload()` was flat even before, which proves the native objects themselves free correctly when someone frees them; the leak was ownership.
- **KV growth:** llama.cpp allocates the whole `n_ctx` KV buffer when the context is created, so KV growth never shows up as footprint growth. It shows up as **logical positions** filling the buffer, which is the reuse failure at turn 27.
- **Allocator caching:** after the fix, the first few turns raise the footprint from 8 to about 85 MB (Metal heaps, malloc zones and the first context's buffers), then it plateaus. The facade's residual drift is about 0.13 MB per turn (+2.6 MB from turn 10 to 30), while the direct load/unload loop is exactly flat. So the residual is allocator fragmentation in the Swift/concurrency layer, not native contexts.

### 1.3 Fixes

- **Deterministic ownership.** `LlamaNativeHandles` owns the model and context exclusively and frees them in `free()` (called by `unload()`) or `deinit`, whichever comes first. Idempotent.
- **One-shot facade releases its runtime.** `generate`/`stream` now end every request with `unload()` (one-shot) or a pool release (managed), on success, error and cancellation. No unload-after-every-turn in managed mode: the model stays loaded and is reused.
- **Per-request KV reset.** `llama_memory_clear(llama_get_memory(ctx), true)` at the start of each `generate`, so a reused runtime is correct and isolated per request.
- **Context-overflow protection.** A prompt that doesn't fit `n_ctx` fails with a typed `LlamaCppError.contextOverflow`, and generation is capped at the remaining room (`finishReason: "length"`) instead of a decode failure.
- **Cancellable, batch-safe prefill.** The prompt is decoded in `n_batch` chunks with a cancellation check between chunks.
- **Metrics.** Decode tok/s excludes prefill; `promptTokens` and `promptTokensPerSecond` are reported.
- **`llama_backend_init` runs once** per process.
- **Opt-in prefix reuse (`LlamaCppConfig.reusePromptPrefix`, off by default).** The context tracks exactly which tokens are in its KV. A request keeps the longest common token prefix, removes the rest with `llama_memory_seq_rm` (falling back to a full clear when partial removal isn't supported), and decodes only the new tokens. It always re-decodes at least the last prompt token, so the logits are fresh. Validated on Qwen2.5-0.5B and 1.5B over a 10-turn conversation with an unrelated request in the middle (`promptPrefixReuseHitsAndMatchesFullPrefill`): cache hits from turn 2, **10/10 turns byte-identical** to a full prefill, and the unrelated request is identical too (isolation). It is opt-in rather than default because a reused prefix is decoded in different batches than a full prefill, and llama.cpp does not guarantee batch-invariant numerics (identical here, not proven in general). The default stays at your decision.

## 2. Managed SDK inference

`EshRuntime(…, lifecycle: .managed(...))` (and the same parameter on `makeDefault`, `withEmbeddedGGUF` and `makeWithEmbeddedGGUF`) routes text requests through the **same infrastructure as `esh serve`**. Nothing is re-implemented:

| Concern | Component reused |
|---|---|
| Load dedup, reuse, LRU/idle/budget eviction, admission and concurrency, awaited shutdown | `RuntimeLifecycleManager` (one per `EshRuntime`, created on first use) |
| Live load gate | `loadRuntimeGuarded` → `ModelLoadSafetyGate` → `MemorySafetyPreflight` |
| KV-growth guard | `ContextGrowthGuard` (new shared helper, now also used by `ExternalInferenceService`, so serve and SDK run one implementation) → `ensureHeadroom` + `KVCacheEstimator` |
| Cache accounting | request `Metrics.memoryBytes`/`residentCacheBytes`/`prefixCacheMode` into `release(…)`, so the pool budgets measured numbers |
| Memory pressure | `monitorPressure()` (system events) plus a periodic `evictIdle()` sweep |
| Status | `RuntimePoolStatus`, the same type as `GET /v1/runtime` |

One-shot stays the default, so existing consumers are source- and behavior-compatible (apart from no longer leaking). Public additions: `EshRuntimeLifecycle`, `EshManagedLifecycleConfiguration`, `EshRuntimeStatus`, `runtimeStatus()`, `prewarm(modelID:)`, `shutdown()`, `textModelReadiness(_:)` / `EshTextModelReadiness`, `BackendLifecycleTraits` with `InferenceBackend.lifecycleTraits`, and `ContextGrowthGuard`. `unload(modelID:)` and `unloadIdleRuntimes()` now also cover pooled text models.

## 3. Platform split

| | macOS | iOS |
|---|---|---|
| Embedded GGUF (`EshLlamaCpp`), one-shot and managed | ✅ measured (§1, §5) | ✅ same code; build-verified in CI (probe app now runs `.managed()` too); **not measured on a device** in this round |
| MLX text (`EshMLXText`) | ✅ one-shot and managed (persistent worker, `live` by default) | ❌ by design (Python worker via `Process`). The module now compiles on iOS to an `MLXBackend` stub that reports unavailable (new CI gate) |
| Apple Foundation Models | ✅ not pooled (system-owned) | ✅ not pooled |
| MLX `live`/`tokens` prefix caching | ✅ | ❌, not claimed |
| Shared lifecycle (pool, gate, pressure, shutdown) for embedded GGUF | ✅ | ✅ portable EshCore code; `SystemRuntimePressureSource` uses the platform's memory-pressure source |

## 4. Defaults and capabilities

- The doc comment on `EshRuntime.init()` claimed "macOS → MLX + GGUF + Apple". It is Apple Foundation Models only on every platform; fixed, with how to wire other backends.
- The root `Package.swift` header claimed only portable products and no external dependencies; corrected (the opt-in EshVision/EshImageGen products use the mlx-swift graph). The EshMLXText comments now state that it is macOS-only with an iOS stub.
- Backends declare `BackendLifecycleTraits` (residency, in-process, prefix reuse, context bounded at load, cancellation during prefill, serialization, iOS support). `runtimeStatus().backends` exposes them per wired backend; MLX reports its **effective** prefix-reuse mode using the bridge's own rule.
- **Readiness.** Capability-model readiness (`modelOptions(for:)`) was already public. Text-model readiness is now public too: `textModelReadiness(_:)`, built from the same checks a request runs, and it loads nothing.

## 5. SDK vs `esh serve` benchmarks

`benchmarks/sdk_vs_serve.py` runs the same workload through the public SDK (`SDKRuntimeBenchmark`, one-shot and managed) and through `esh serve`. Raw results are in `benchmarks/results/sdk-vs-serve.jsonl`, and `benchmarks/summarize_sdk_vs_serve.py` prints this table.

**Workload:**
- A 10-turn agent conversation over a ~1.6K-token code context: max_tokens 96, temperature 0, streamed, with TTFT measured by the client.
- Then 3 conversations at once, each compared with its own serial run.

**Equivalent configuration:**

| | SDK | Serve |
|---|---|---|
| MLX | `MLXBackend(persistent: true)` under `.managed()` | `ESH_MLX_PERSISTENT=1` |
| GGUF | `LlamaCppEmbeddedBackend` with n_ctx 8192 | llama-server with `-c 8192` |

**Memory** is RSS of the process plus its children, sampled every 0.5 s, for both sides.

| Model | Config | TTFT turn 1 (s) | TTFT follow-ups, median (s) | 10-turn session (s) | Prefill tok/s (median) | Decode tok/s (median) | Prefix-cache hits | Model loads | 3 concurrent chats (s) | Concurrent = serial | Peak RSS (GB) | RSS after shutdown (GB) | Leftover processes | Text = SDK managed |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| llama-3-8b-instruct-4bit | sdk-managed | 20.79 | 0.63 | 33.81 | 85.59 | 32.67 | 9/9 | 1 | 46.11 | yes | 5.41 | 0.05 | 0 | 10/10 |
| llama-3-8b-instruct-4bit | sdk-oneShot | 16.68 | 18.17 | 202.1 | 226.66 | 34.95 | 0/9 | 1 per request | skipped | — | 5.6 | 0.03 | 0 | 10/10 |
| llama-3-8b-instruct-4bit | serve | 17.14 | 0.48 | 28.02 | — | — | — | 1 | 38.72 | yes | 4.83 | — | 0 | 10/10 |
| qwen2.5-1.5b-instruct-q4km | sdk-managed | 1.79 | 1.66 | 18.22 | 1140.54 | 61.7 | 0/9 | 1 | 11.19 | yes | 1.31 | 0.15 | 0 | 10/10 |
| qwen2.5-1.5b-instruct-q4km | sdk-managed+reuse | 1.74 | 0.06 | 3.55 | 8307.25 | 64.41 | 9/9 | 1 | 10.94 | yes | 1.31 | 0.15 | 0 | 10/10 |
| qwen2.5-1.5b-instruct-q4km | sdk-oneShot | 1.91 | 1.96 | 21.02 | 1089.03 | 64.42 | 0/9 | 1 per request | 11.12 | yes | 3.68 | 0.27 | 0 | 10/10 |
| qwen2.5-1.5b-instruct-q4km | serve | 2.42 | 0.07 | 4.41 | — | — | — | 1 | 5.29 | yes | 1.45 | — | 0 | 7/10 |

**Reading it:**
- **Managed MLX through the SDK behaves like `esh serve`.**
  - One load; `live` prefix cache by default; 9/9 follow-ups hit the cache; follow-up TTFT 0.63 s vs serve's 0.48 s.
  - Identical text on 10/10 turns; concurrent chats match their serial runs.
  - Measured memory and the 0.24 GB resident cache are reported in `runtimeStatus().pool`, exactly as `GET /v1/runtime` reports them.
  - Session 33.8 s vs 28.0 s. The gap is mostly turn 1 (20.8 s vs 17.1 s cold start) and the concurrent phase (46 s vs 39 s). The SDK side ran inside a debug `swift test` process that was also spawning `ps` every 0.5 s to sample memory. That gap is reported as measured, not explained away.
- **One-shot MLX through the SDK** reloads the 8B model and re-prefills every turn: 18 s median follow-up TTFT, 202 s per session (**6× slower than managed**). It now leaves nothing behind (no worker, state file or sidecar), but it is the wrong mode for chat.
- **Embedded GGUF:**
  - Managed loads once and uses about a third of one-shot's peak memory under concurrency: 1.31 vs 3.68 GB, because one-shot loads one model copy per concurrent request.
  - Without prefix reuse every turn re-prefills (1.7 s TTFT), so serve's llama-server, which has a prompt cache, was 4× faster.
  - **With `reusePromptPrefix`, the SDK is faster than serve**: 3.55 s vs 4.41 s per session, 0.06 s vs 0.07 s follow-up TTFT, 1.31 vs 1.45 GB peak. All SDK GGUF configurations produced identical text.
  - Serve differs on 3/10 turns because llama-server is a different llama.cpp build from the vendored xcframework, not because of the lifecycle.
- **Memory after shutdown:** RSS returns to 0.03–0.27 GB, and no worker or llama-server processes are left behind in any configuration.
- **Decode throughput** is unchanged by the lifecycle: 33–35 tok/s for MLX 8B and 62–64 tok/s for GGUF 1.5B.

## 6. Limitations

1. **iOS is build-verified, not device-measured.** The embedded backend and the managed lifecycle are the same code on iOS and macOS, and CI builds EshCore, EshRuntime, the EshMLXText stub and the probe apps (the probe now also runs `.managed()`). The memory numbers here are macOS (`phys_footprint`). A device run of `Examples/EshIOSProbe` is the remaining step.
2. **Embedded GGUF prefix reuse is opt-in and single-sequence.** It was identical to full prefill on Qwen2.5 0.5B/1.5B, but llama.cpp doesn't guarantee batch-invariant numerics, so it isn't the default without your approval. One cached sequence per loaded model: alternating chats on one model evict each other's prefix.
3. **One request at a time per loaded GGUF model**, and a decoding request occupies a cooperative-pool thread (llama.cpp calls are synchronous inside the actor). Concurrent chats on one model queue; different models run in parallel up to `maxConcurrentRequests`.
4. **The SDK's embedded GGUF and serve's llama-server are different llama.cpp builds** (vendored xcframework pin vs the installed `llama-server`). Their greedy outputs can differ on some turns; that is the engine, not the lifecycle (see §5).
5. **Real system memory pressure wasn't triggered** (it would affect every app). The pool's reactions are unit-tested with injected events, as for `esh serve`.
6. **A managed runtime dropped without `shutdown()`** cancels its background tasks and frees native GGUF contexts through their owner's `deinit`. A persistent MLX worker exits when its stdin closes, which is not awaited. Call `shutdown()` on teardown.
7. **Apple Foundation Models are not pooled** (the system owns the model). The facade passes them through unchanged.
8. **The MLX one-shot SDK path can't share caches across calls** (each call is a new worker), so its follow-up turns cost a full model load plus prefill. Use `.managed()` with `MLXBackend(persistent: true)` for chat.
9. **Disk:** the bench store reuses existing weights by symlink. Running `sdk_vs_serve.py` needs a store containing both models.
