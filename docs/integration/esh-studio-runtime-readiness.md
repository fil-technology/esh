# esh Studio runtime readiness: integration handoff

**For:** the esh Studio coding agent (macOS + iOS). **Prepared:** 2026-11-14.

- **Code state:** esh `main` at `7a64af6`. That includes #23, #24, #25 and #26 (`1f7f195`) plus #27, the `live` default for the persistent MLX worker, merged as `7a64af6`.
- **Paths:** relative to the esh repo root. Line numbers are pinned to `1f7f195` unless marked `#27`; #27 shifts some bridge and EshCore line numbers on `main`, so search by symbol name there.
- **Scope:** this document only describes esh. It changes no defaults and no Studio code.
- **Evidence:** `docs/research/ghost-infer-2026-11/` (A–H). Read **H** (final readiness) and **G** (hardening) for the measurements.

## 0. Read this first: three facts that decide the integration

1. **The `EshRuntime` facade, Studio's stable entry point, has no warm pool for text.**
   - `generate` and `stream` load a runtime **per call** (`Sources/EshRuntime/EshRuntime.swift:611` `loadRuntime` → `plan.backend.loadRuntime`). They never call `runtime.unload()` and never use `RuntimeLifecycleManager`.
   - Consequences:
     - No cross-call prefix reuse: each call gets a fresh MLX state file.
     - No `live` cache.
     - No pool memory accounting, no cache eviction, and no pool-level KV-growth guard.
   - Most of what's measured in G and H was validated through **`esh serve`** (the macOS CLI's pooled server), **not** through `EshRuntime`.
   - To get it in Studio, assemble the pooled path yourself from public EshCore types (§4.2). That path is unvalidated in Studio.
2. **On iOS, none of the new MLX text capabilities exist.**
   - `EshMLXText` launches a Python subprocess (`Process`) with no platform guard: `Sources/EshMLXText/ProcessRunner.swift:68`, `MLXRuntime.swift:78,270`, `MLXWorker.swift:48`. Foundation's `Process` doesn't exist on iOS, so **this target doesn't compile for iOS**; CI never builds it for iOS.
   - iOS text generation is **Apple Foundation Models** (iOS 26+) and **embedded GGUF** (`EshLlamaCpp`) only.
   - The Python-bridge features — prefix caching, `live`, the worker-side KV guard, lookup speculation and the speech catalog engines — are **macOS-only**.
3. **The facade's default backend set is Apple Foundation Models only**, on macOS too.
   - `EshRuntime()` / `makeDefault()` use `[.apple: AppleBackend()]` (`EshRuntime.swift:275,872`; `Sources/EshCore/Services/InferenceBackendRegistry.swift:53-57`).
   - The doc comment at `EshRuntime.swift:273-274` claiming "macOS → MLX + GGUF + Apple" is **wrong**.
   - MLX text in Studio requires passing `.mlx: MLXBackend(...)` to `makeDefault(backends:)`, with paths from `MLXTextRuntimeProvisioner` (`Sources/EshMacCapabilities/MLXTextRuntimeProvisioner.swift:35-75`).
   - GGUF requires `EshRuntime.withEmbeddedGGUF` / `makeWithEmbeddedGGUF` (`Sources/EshLlamaCpp/EshRuntimeEmbeddedGGUF.swift:14,29`).

**Suspected leak, high priority to verify (code reading only, not runtime-confirmed):**
- `LlamaContext` frees its model and context only in `unload()` (`Sources/EshLlamaCpp/LlamaCppEmbeddedBackend.swift:277-279`), and nothing in `EshLlamaCpp` has a `deinit`.
- The facade never calls `unload()`, so each facade call on embedded GGUF probably keeps that load's model and context allocated.
- Verify on iOS (memory after N chat turns) before shipping chat on embedded GGUF through the facade. The fix belongs in esh: unload after the call, or a `deinit`, or a facade warm pool.

## 1. Status legend

| Label | Meaning |
|---|---|
| **Merged** | On esh `main` (`7a64af6`) |
| **Unmerged** | Implemented in an open PR; not on `main` (no capability in this document is in that state any more) |
| **Validated (macOS, serve)** | Measured on real models on an M1 Pro, through `esh serve` / `esh infer` / the bridge worker |
| **Validated (macOS, SDK)** | Exercised through the `EshRuntime` facade on macOS |
| **Validated (iOS)** | Exercised on iOS. **Nothing in this document is.** iOS CI only *builds* `EshCore`/`EshRuntime` and the embedded-GGUF probe apps (`.github/workflows/ci.yml:70-147`) |
| **Experimental** | Opt-in, off by default, not recommended for automatic use yet |
| **Unsupported** | Not available on that platform or path |

A PR existing does not make a feature production-ready. Studio-facing readiness additionally needs the SDK path (§4) and iOS validation.

## 2. Capability matrix

| Capability | Status | macOS via `EshRuntime` (SDK) | macOS via pooled path (`esh serve` or the §4.2 assembly) | iOS |
|---|---|---|---|---|
| Model-load safety gate | **Merged** · Validated (macOS, serve) | ✅ facade runs it (`EshRuntime.swift:612`) | ✅ | Code compiles (EshCore). **Not validated** on iOS |
| Token-exact prefix caching (`tokens`) | **Merged**, default · Validated (macOS, serve) | ⚠️ active, but **no cross-call reuse** (new runtime and state file per call) | ✅ | Unsupported (MLX bridge) |
| Persistent `live` KV caching | **Merged** (#27, `7a64af6`): default **only** in the persistent MLX worker · Validated (macOS, serve) | ❌ (no pool; a persistent worker per call would be wrong) | ✅ with `ESH_MLX_PERSISTENT=1` | Unsupported |
| Runtime memory accounting (caches in the pool budget) | **Merged** · Validated (macOS, serve) | ❌ | ✅ | Code compiles; no iOS runtime reports caches |
| KV-growth protection | **Merged** · Validated (macOS, serve) | ⚠️ worker-side check only (MLX bridge); **no pool-level guard** (facade bypasses `ExternalInferenceService`) | ✅ pool + worker | Unsupported on the MLX path; embedded GGUF is bounded by `n_ctx` |
| Cache eviction (idle caches, pressure) | **Merged** · Validated (macOS, serve; pressure events via unit tests only) | ❌ | ✅ | Unsupported |
| Model switching | **Merged** · Validated (macOS, serve) | ⚠️ works, but each call reloads; nothing unloads | ✅ pool keeps up to 3 resident, LRU | Embedded GGUF: per-call load (see the leak above) |
| Streaming and cancellation | **Merged** (pre-existing; unchanged) | ✅ | ✅ | ✅ Apple FM / embedded GGUF (build-only CI) |
| Runtime metrics (new fields) | **Merged** (including #27's `prefixCacheMode`/`prefixCacheFallback`) · Validated (macOS, serve) | ✅ `EshGenerationResult.metrics` passes them through (`EshRuntime.swift:99`) | ✅ plus `GET /v1/runtime` (serve only) | Fields exist; MLX-only fields stay nil |
| GGUF tuning (`ngram-simple`, KV type) | **Merged** · **Experimental** · Validated (macOS, serve) | ❌ (applies to `llama-server` only; the facade's GGUF is embedded) | ✅ `esh serve` llama-server only | Unsupported |
| Speculative decoding (MLX lookup) | **Merged** · **Experimental** · Validated (macOS, bridge) | ⚠️ env-driven inside the bridge; applies to any MLX request | ✅ | Unsupported |
| Model capability metadata (`modelOptions(for:)`) | **Merged** · Validated (macOS, mlx_audio speech) | ✅ `EshRuntime.swift:793` | ✅ | Returns `.unsupportedOnPlatform` for macOS-only families (`EshRuntime.swift:777`) |
| Lifecycle and clean shutdown | **Merged** · Validated (macOS, serve) | ⚠️ no text shutdown API; persistent workers would be unmanaged | ✅ `RuntimeLifecycleManager.shutdown()` | Unsupported (MLX); embedded GGUF see the leak above |

## 3. Capability details

Each subsection gives the implementation, public interface, platforms, configuration, default, limitations, what the consumer must do, and tests.

### 3.1 Model-load safety gate
- **Implementation:**
  - `Sources/EshCore/Runtime/ModelLoadSafetyGate.swift`: `ModelLoadSafetyGate` :19, `ModelLoadRefused` :5, `InferenceBackend.loadRuntimeGuarded(for:root:)` :48.
  - Rules: `MemorySafetyPreflight.evaluate` (`MemorySafetyPreflight.swift:23`); `smallModelFloorGB = 4`, `swapDiskFloorGB = 3`.
- **Public interface:**
  - `ModelLoadSafetyGate.check(_:root:additionalGB:) throws` and `.verdict(for:additionalGB:host:)`.
  - The facade maps a refusal to `EshRuntimeError.insufficientMemory(modelID:reason:)` (`EshRuntime.swift:623-628`).
- **Platforms:** EshCore (portable); host probe `HostResourceProbe` (`ResourceAwareSelection.swift:221`). Validated on macOS only.
- **Configuration / default:** always on. Models under 4 GB are never gated.
- **Limitations:**
  - Sizing is the catalog's measured peak, or else the on-disk size × 1.05. That's conservative for MoE, optimistic for very long contexts (§3.5 covers growth).
- **Consumer must:**
  - Handle `insufficientMemory` as a user-actionable error (free memory or disk; no reboot needed).
  - Never retry in a loop.
- **Tests:** `Tests/EshCoreTests/ModelLoadSafetyGateTests.swift` (5); `MemorySafetyPreflightTests`.

### 3.2 Token-exact prefix caching (`tokens`)
- **Implementation (macOS, bridge):**
  - `Tools/mlx_vlm_bridge.py`: `_prefix_cache_mode` :1295, `_token_prefix_reuse` :1371, `_finish_token_prefix` :1412, `_write_kv_sidecar` :1478.
  - Bundled copy: `Sources/EshMacCapabilities/Resources/bridge/mlx_vlm_bridge.py`, which CI checks is identical.
- **Behavior:**
  - Records the exact token ids in the KV cache, reuses the longest common token prefix with the new prompt, trims, and prefills the rest.
  - The snapshot is a versioned `.kv.safetensors` sidecar next to the state file in `<tmp>/esh-mlx-state/<pid>-<uuid>.json` (`Sources/EshMLXText/MLXStateFiles.swift:11`).
  - A disk guard skips snapshots that would breach the 3 GB swap floor (`_snapshot_skip_reason` :1205).
- **Public interface:**
  - None to call. Observe it through `Metrics.cacheHit` / `cachedTokens`.
  - Configuration is environment-only: `ESH_MLX_PREFIX_CACHE=tokens|live|legacy`.
- **Default:** `tokens` (merged). Rollback: `ESH_MLX_PREFIX_CACHE=legacy`.
- **Validated (macOS):**
  - Llama-3-8B and Mistral-7B: byte-identical to a full recompute on every turn.
  - Qwen3-0.6B: differs only at diagnosed bf16 near-ties.
  - Legacy *duplicated KV tokens* on Mistral's template (H §2, G §4).
- **Limitations:**
  - Reuse only happens across turns **of the same runtime instance**, which the facade never keeps.
  - One snapshot per runtime, so interleaved conversations overwrite each other. That's correct, just slower.
  - Imported caches (`importRuntimeCache`) are legacy-format, so they miss in `tokens` mode.
- **Consumer must:** use the pooled path (§4.2) to benefit. No API changes are needed.
- **Tests:**
  - `Tests/Python/test_prefix_cache.py` (real-MLX equivalence on tiny models).
  - `benchmarks/validate_prefix_cache.py` (real models).

### 3.3 Persistent `live` KV caching
- **Implementation (macOS, bridge worker):**
  - Live slots `_best_live_slot` :1358, budget `_live_cache_budget_bytes` :1321, drop `_drop_live_caches` :1342.
  - The worker loop `mlx_serve` :2805 handles the `drop-caches` op :2872.
  - Swift side: `MLXPersistentRuntime` (`Sources/EshMLXText/MLXPersistentRuntime.swift`, `releaseCaches` :140) and `MLXWorkerProcess.dropCaches`.
- **Status:**
  - **Merged (#27, `7a64af6`):** the default **only inside the persistent worker** (`ESH_MLX_PERSISTENT=1`, pool-owned). One-shot paths stay `tokens` even if `live` is requested.
  - Rollback: `ESH_MLX_PREFIX_CACHE=tokens`.
  - If `live` can't hold a session, it falls back to the token-exact snapshot (#27).
- **Behavior:**
  - Keeps the last N session KV caches resident (slots, default 2).
  - Matches them by token content, like llama.cpp's slot selection; esh request session IDs are random.
  - A cache is popped while its request runs, so it's never shared with another request or dropped mid-generation.
  - Budget: `ESH_MLX_LIVE_PREFIX_MAX_BYTES`, default min(25% of RAM, 8 GiB).
  - Not retained under critical pressure.
- **Validated (macOS, serve, Llama-3-8B):** 10-turn agent session 123.0 s → 26.9 s (H §4). Every turn byte-identical; correct with concurrency, model switching, a tiny budget and restart; no orphaned processes.
- **Limitations:**
  - Needs a long-lived worker, so it's **unusable through the facade**.
  - Holds 0.2–0.25 GB per session at about 1.7K tokens (capped).
  - A separate-process `exportRuntimeCache` sees no tensors in `live` mode.
- **Consumer must:**
  - Own one `RuntimeLifecycleManager` for the app's lifetime and route MLX through `MLXBackend(persistent: true)` (§4.2).
  - Call `shutdown()` on quit.
  - Never create a persistent runtime outside a pool.
- **Tests:** `Tests/Python/test_prefix_cache.py` (isolation, drop, budget, slots, fallback); `benchmarks/serve_live_validation.py`.

### 3.4 Runtime memory accounting
- **Implementation:**
  - `Sources/EshCore/Runtime/RuntimeLifecycleManager.swift`: `release(modelID:measuredMemoryBytes:residentCacheBytes:)` :117 (#27 adds `prefixCacheMode:`), `status()` :511.
  - The budget is weights estimate + reported caches.
  - `CacheMemoryReporting` (`RuntimeLifecycle.swift:21`); `Metrics.residentCacheBytes` (`Domain/Metrics.swift:21`).
  - `RuntimePoolStatus.residentCacheGB` (`RuntimeLifecycle.swift:120`). #27 adds per-resident `prefixCacheMode` and `residentCacheBytes`.
- **Platforms:** EshCore (portable). The only cache reporter is `MLXPersistentRuntime`, which is macOS-only.
- **Consumer must:**
  - When using the pool, release with the runtime's latest metrics, as `RuntimeLifecycleManager.withRuntime` (:132) and `ExternalInferenceService` already do.
  - Expose `status()` in Studio diagnostics if wanted. `esh serve` exposes it as `GET /v1/runtime` (`macos/Sources/esh/WebExperienceData.swift:73`).
- **Tests:** `Tests/EshCoreTests/RuntimeLifecycleHardeningTests.swift` (`ResidentCacheAccountingTests`).

### 3.5 KV-growth protection
- **Implementation:**
  - **Pool:** `RuntimeLifecycleManager.ensureHeadroom(forAdditionalBytes:modelID:)` :265.
    - Judged by `liveGrowthGate` (MemorySafetyPreflight in growth mode, no small-model floor).
    - If it doesn't fit: release idle caches, then evict idle models LRU-first, then throw `RuntimeLifecycleError.insufficientMemoryForContext` (`RuntimeLifecycle.swift:141`).
    - Estimate from `KVCacheEstimator` (`Sources/EshCore/Runtime/KVCacheEstimator.swift:6`, reads `config.json`).
    - Called by `ExternalInferenceService.guardContextGrowth` (`Sources/EshCore/Services/ExternalInferenceService.swift:693`) for MLX.
  - **Worker (bridge):**
    - `_ensure_kv_headroom` :1273 checks before prefill with exact tokens.
    - During generation it checks pressure every `_KV_GUARD_CHECK_EVERY = 256` tokens (:1225), stopping with `finishReason: "memory_pressure"`.
    - Metrics: `kvGrowthBytes`, `kvBytesPerToken`, `kvGuardFreedBytes`. These are bridge JSON keys that aren't decoded into `Metrics`.
- **Platforms:** the pool part is portable code; the worker part is macOS MLX only.
- **The facade does not call the pool guard** (it bypasses `ExternalInferenceService`; even `EshRuntime.inferText` :408 goes through `generate`). Only the worker-side check protects facade MLX calls.
- **Consumer must:**
  - Handle `insufficientMemoryForContext` (show "shorten the conversation or max tokens").
  - Treat `finishReason == "memory_pressure"` as a partial answer, not a crash.
- **Tests:** Swift `ContextGrowthGuardTests` (4), `KVCacheEstimatorTests` (5); `benchmarks/validate_kv_guard.py` (real model).

### 3.6 Cache eviction
- **Implementation:**
  - `releaseIdleCaches(excluding:)` :292.
  - `handle(_ RuntimePressureEvent)` :308: warning releases idle caches; critical also evicts idle models.
  - `monitorPressure(_:) -> Task` :322, with `SystemRuntimePressureSource` (`Runtime/RuntimePressure.swift`).
  - The worker processes `drop-caches` between requests.
- **Never touched:** residents with active requests, or a cache popped by a running request.
- **Consumer must:**
  - Start `pool.monitorPressure()` once for the app's lifetime, as `esh serve` does at `macos/Sources/EshMacRuntime/Services/OpenAICompatibleService.swift:949`.
  - On iOS this is also the natural hook for `didReceiveMemoryWarning`, but no iOS runtime reports caches yet.
- **Not validated:** a real system-wide pressure event (unit tests use injected events).

### 3.7 Model switching
- **Pool:**
  - Up to `maxResidentModels` (default 3) are kept warm; LRU eviction; deduplicated loads.
  - A load waits for its own evictions to finish before the gate measures memory.
  - **Validated:** MLX ↔ GGUF alternation in `esh serve`, both resident, continuation identical.
- **Facade:** every call loads afresh. That's correct but slow, and for embedded GGUF possibly leaking (§0).

### 3.8 Streaming and cancellation (unchanged by #23–#25)
- **Facade:** `stream(_:) -> AsyncThrowingStream<EshGenerationEvent, Error>` (`EshRuntime.swift:442`; events: token, reasoningDelta, completed).
  - Cancelling the consuming task cancels the inner task (`onTermination` :498) and surfaces `CancellationError`.
- **Per backend:**
  - **One-shot MLX:** SIGTERM, then SIGKILL after 1.2 s (`MLXRuntime.swift:133-135,280-288`).
  - **Persistent worker:** an `op: "cancel"` message (`MLXWorker.swift:162-166`).
  - **llama-server:** URLSession cancel (`LlamaServerProcess.swift:118-136`).
  - **Embedded llama:** a per-token `Task.isCancelled` check (`LlamaCppEmbeddedBackend.swift:132,251`).
- **Consumer must:**
  - Cancel the consuming `Task` to stop generation.
  - Never assume a partial answer after cancellation (the facade throws).

### 3.9 Runtime metrics
- **`Metrics`** (`Sources/EshCore/Domain/Metrics.swift`), all optional and backward-compatible to decode:
  - Pre-existing: `ttftMilliseconds`, `tokensPerSecond`, `promptTokens`, `generationTokens`, `finishReason`, `cacheHit`, `cachedTokens`, `memoryBytes`, `cacheSizeBytes`.
  - New: `residentCacheBytes`, `promptTokensPerSecond`, `draftTokens`, `draftAcceptedTokens`, `kvModeFallback`.
  - Added in #27: `prefixCacheMode`, `prefixCacheFallback`.
- **GGUF (llama-server) timings:** parsed by `LlamaServerTimings` (`Runtime/LlamaServerTimings.swift:6`).
- **`kvModeFallback`:** says when the automatic KV mode degraded, e.g. TurboQuant → raw because `mlx_vlm` is missing from the managed venv.
- **Consumer:** read `EshGenerationResult.metrics` / the `.completed` event. Fields a backend doesn't produce are nil.

### 3.10 GGUF tuning (experimental)
- **Implementation:**
  - `LlamaServerTuning` (`Sources/EshCore/Runtime/LlamaServerTuning.swift:14`), allow-listed environment only: `ESH_LLAMA_SPEC_TYPE`, `ESH_LLAMA_DRAFT_MAX`, `ESH_LLAMA_KV_TYPE`.
  - Consumed only by `macos/.../GGUF/LlamaServerProcess.swift:32`, i.e. llama-server under `esh serve`.
- **Not applicable to:** the facade's embedded GGUF (`EshLlamaCpp`), on macOS or iOS.
- **Default:** off.
- **Measured:** code edits +242% to +359% on small Q4 models; −13% when the model doesn't copy its input. `ngram-map-k` crashed llama-server b8660; q8_0 KV was −13% to −20% at short context.

### 3.11 Speculative decoding (experimental)
- **MLX lookup speculation:**
  - Bridge: `_lookup_spec_settings` :991, `_lookup_stream_generate` :1020, `_LookupPace` :896.
  - Enable with `ESH_MLX_LOOKUP_SPEC=1` (exact mode: `ESH_MLX_LOOKUP_EXACT=1`). Greedy only, otherwise it falls back.
  - macOS only. Code edits +62% to +90% decode on 7–8B models; −7% to +3% elsewhere.
  - **Not bit-exact:** MLX batched verification is batch-invariant only for ≤ 4–5 tokens at short context and ≤ 2 at 8K and beyond. Exact mode loses the speedup.
- **GGUF:** see §3.10.
- **Default:** off. **Do not enable automatically in Studio.**
- **Possible future:** an intent-gated policy (code/agent intents, greedy, non-deterministic callers only); see H §7.

### 3.12 Model capability metadata
- **API:**
  - `EshRuntime.modelOptions(for: CapabilityID) async -> [ModelOptionAvailability]` (`EshRuntime.swift:793`).
  - `CapabilityProviderDescriptor.modelOptions` (`Sources/EshCore/Runtime/CapabilityProvider.swift:72`).
  - Types: `CapabilityModelOption`, `ModelOptionReadiness` (ready / needsSetup / downloadRequired(bytes) / unsupportedOnThisMachine / notValidated / unsupportedOnPlatform), `ModelOptionFit`, `ModelOptionAvailability` (`Runtime/CapabilityModelOption.swift`).
- **Data:**
  - The validated catalog `Sources/EshMacCapabilities/Resources/catalog/validated-models.json`: 11 speech models; CSM failed (gated repo).
  - Loader: `ValidatedModelCatalog` (`Sources/EshMacCapabilities/ValidatedModelCatalog.swift`). Docs: `docs/VALIDATED_MODEL_CATALOG.md`.
- **Platforms:** macOS (Python engines). iOS returns `.unsupportedOnPlatform` for these families.
- **Consumer:**
  - Show only `isRunnable` options as selectable; show the rest with their `note`.
  - Select a model with `model:` = the provider ID and `options["model"]` = the option ID.

### 3.13 Lifecycle and clean shutdown
- **Pool:**
  - `RuntimeLifecycleManager.shutdown() async` (:390) unloads every resident and **waits** for each teardown.
  - `esh serve` awaits it on SIGINT/SIGTERM (`macos/Sources/esh/Commands/ServeCommand.swift:165`). This prevents orphaned `llama-server` processes.
- **Workers:**
  - The MLX worker also exits on stdin EOF.
  - Crash leftovers in `<tmp>/esh-mlx-state` and `<tmp>/esh-mlx-staging` are swept by the next runtime or bridge start (dead-owner only).
- **Facade:** has no text shutdown API, because it holds nothing between calls (§0).
- **Consumer must, with the pooled path:**
  - Call `await pool.shutdown()` on app termination (macOS `applicationShouldTerminate` → reply later).
  - Never leave persistent workers unowned.

## 4. Integration guidance for Studio

### 4.1 What works today with no esh changes
- **Facade text:** Apple FM (macOS and iOS 26+), embedded GGUF (`withEmbeddedGGUF`), and MLX one-shot on macOS (pass `MLXBackend()` with provisioned paths).
- **Capabilities:** `execute` / `stream(ExecutionRequest)` and `modelOptions(for:)`.
- **Metrics:** the new `Metrics` fields, where the backend provides them.
- **Model-load safety gate.**

### 4.2 macOS: getting warm residency, `live`, accounting, eviction and the growth guard (needs a decision)
Everything below is public on `main`, but the composition is **not provided or validated as an SDK API**. Two options:

- **A (recommended for esh):** an esh follow-up adds a warm pool to the facade text path. This is a known gap in `docs/integration/esh-studio-extreme-inference.md` §7: `EshRuntime` would own a `RuntimeLifecycleManager`, acquire and release per call, and expose `shutdown()`. Studio then gets everything through the stable `EshRuntime` contract.
- **B (Studio-side, interim):** assemble the pool from EshCore.
  - Build `RuntimeLifecycleManager(usableBudgetGB:estimator:loader:residencyProbe:)` (`RuntimeLifecycleManager.swift:76`) whose loader calls `MLXBackend(persistent: true).loadRuntimeGuarded(for:)` for MLX installs. Mirror `OpenAICompatibleService.makeLifecycleManager` (`macos/.../OpenAICompatibleService.swift:928`, about 20 lines).
  - Start `monitorPressure()`.
  - Run text through `ExternalInferenceService(modelStore:sessionStore:cacheStore:registry:lifecycleManager:)` (`ExternalInferenceService.swift:28`).
  - Call `shutdown()` on quit.
  - **Caveats:**
    - `ExternalInferenceService` is EshCore (treated as SPI in `docs/SDK_API_CONTRACT.md`), so it's not covered by the stable contract.
    - Studio would then own pool configuration.
  - **Never** use `MLXBackend(persistent: true)` with the plain facade: that starts a worker with a full weight load per call and never shuts it down.

### 4.3 iOS
- **Supported:** Apple FM (iOS 26+) and embedded GGUF. Everything MLX/Python-based is unsupported, as are the speech catalog engines.
- **Before shipping embedded GGUF chat through the facade:** verify the suspected per-call leak (§0) on a device.
- **Validation gap:** no esh capability in this document has been validated on iOS.
  - iOS CI builds `EshCore`/`EshRuntime` and the `Examples/EshIOSProbe` / `Examples/EshCleanRoom` apps.
  - It runs no iOS tests.
  - It never builds `EshMLXText`, `EshVision`, `EshImageGen` or `EshMacCapabilities` for iOS.
- **Portable building blocks:** if a future iOS MLX text backend (mlx-swift-lm `MLXLLM`) is added, the pool, metrics, gates and estimators would apply unchanged. The `tokens`/`live` caching would need re-implementing natively, because it lives in the Python bridge.

## 5. API changes and migration for existing consumers

| Change | Source | Impact on Studio |
|---|---|---|
| `Metrics` gained optional fields | #25, #27 | Additive; old JSON still decodes. Nothing to do. |
| `BackendRuntime.prepareBeforeGenerateIsRedundant` (default `false` via extension) | #25 | Additive. Custom `BackendRuntime` conformances compile unchanged. |
| `RuntimeLifecycleManager.init` gained `growthGate:` (defaulted); `release` gained parameters (defaulted) | #25, #27 | Source-compatible. |
| `MemorySafetyPreflight.evaluate` gained `applySmallModelFloor:` / `subject:` (defaulted) | #25 | Source-compatible. |
| `RuntimeLifecycleError.insufficientMemoryForContext` (new case) | #25 | **Exhaustive `switch`es over `RuntimeLifecycleError` must add a case.** |
| `ResidentModelInfo` / `RuntimePoolStatus` gained optional fields | #25, #27 | Additive (the decodable struct ignores missing keys). |
| `CapabilityProviderDescriptor.modelOptions` + `EshRuntime.modelOptions(for:)` | #23 | Additive. |
| `EshMacCapabilities` speech engines: pinned `mlx-audio>=0.6.5,<0.7` + Kokoro G2P provisioning | #23 | First synthesis installs extra Python modules (GPL-3.0 phonemizer/espeak-ng at runtime in the user's managed venv; **never bundle**). |
| MLX state files moved to `<tmp>/esh-mlx-state/` | #25 | None, unless Studio inspected those files. |
| `tokens` prefix cache is the default | #25 | Behavior change for the MLX bridge only. Rollback: `ESH_MLX_PREFIX_CACHE=legacy`. |
| `--kv-bits` / `kvBits` on bf16 models no longer crashes | #25 | Bug fix. |
| `live` default in the persistent worker | #27 (merged, `7a64af6`) | Only affects pooled persistent MLX. Rollback: `ESH_MLX_PREFIX_CACHE=tokens`. |

## 6. Required consumer behavior (checklist)

1. Treat `insufficientMemory`, `insufficientMemoryForContext` and `finishReason == "memory_pressure"` as user-actionable states, not crashes.
2. Cancel generation by cancelling the consuming task.
3. If you adopt the pooled path:
   - one pool per app;
   - `monitorPressure()` started once;
   - `shutdown()` awaited on quit;
   - release runtimes with their metrics;
   - never create persistent MLX runtimes outside the pool.
4. Don't enable experimental flags (`ESH_MLX_LOOKUP_SPEC`, `ESH_LLAMA_SPEC_TYPE`, `ESH_LLAMA_KV_TYPE`, `ESH_MLX_LOOKUP_EXACT`) by default.
5. Expect GPL-3.0 runtime dependencies for Kokoro TTS in the user's venv; never bundle them into the app.
6. Before any iOS chat release on embedded GGUF via the facade, run a memory soak (N turns) to settle the suspected leak.

## 7. Tests and validation evidence

| Area | Where |
|---|---|
| Unit (Swift) | `Tests/EshCoreTests/RuntimeLifecycleHardeningTests.swift`, `ModelLoadSafetyGateTests.swift`, `LlamaServerTuningTests.swift`, `LlamaServerTimingsTests.swift`, `PrefixCacheDiagnostics` (#27), `PrepareSkipTests.swift`; `Tests/EshMLXTextTests/MLXStateFilesTests.swift`; `Tests/EshMacCapabilitiesTests/ValidatedModelCatalogTests.swift` |
| Unit and equivalence (Python, real tiny MLX models) | `Tests/Python/test_prefix_cache.py`, `test_lookup_spec.py` |
| Real models (macOS) | `benchmarks/validate_prefix_cache.py`, `validate_kv_guard.py`, `serve_live_validation.py`, `serve_integration.py`, `esh_infer_bench.py`; results in `benchmarks/results/` |
| CI | Root `swift test` (pyflakes plus a bridge-copy check), macOS package tests, live speech smoke (`.github/workflows/mlx-speech-smoke.yml`), iOS build gates (build-only) |

**Main CI at `1f7f195`:** the mlx speech smoke passed on `0ea01a2` and `dc83fad`; the full CI run on `1f7f195` was still in progress when this was written. Locally on `1f7f195`, the root package (553 tests in the main run plus the other targets) and the macOS package (191 + 20) pass.

## 8. Open items owned by esh (not Studio)

1. A warm pool in the `EshRuntime` text path, with a `shutdown()` API (§4.2 A).
2. Unload or `deinit` for embedded llama contexts; settle the suspected leak.
3. ~~Merge #27~~: done (`7a64af6`).
4. `EshMLXText` is not iOS-buildable: gate it with `#if os(macOS)` or document it as macOS-only in `Package.swift`.
5. Fix the wrong doc comment at `EshRuntime.swift:273-274` and the outdated "no external dependencies" comment at `Package.swift:8-9`.
6. Ashex ↔ `esh serve` structured-output integration: a separate workstream, blocked on disk space. See H §8.
