# esh SDK → esh Studio: integration handoff

**From:** esh `main` at `e1d1271` (#31, managed SDK runtime). **No release tag includes it yet**: the latest tag, `v2.4.0-rc.36`, predates it. Pin Studio to `e1d1271`, or to the first tag cut after it.
**Full reference:** [esh-sdk-managed-runtime.md](esh-sdk-managed-runtime.md). **Measurements:** [managed-sdk-runtime-2026-11.md](../research/managed-sdk-runtime-2026-11.md).

## TL;DR for Studio

1. Build **one** `EshRuntime` per app with `lifecycle: .managed()`, and call `shutdown()` on teardown.
2. Delete any Studio-side pool, load gate or KV-growth check. The SDK owns all of that now, using the same machinery as `esh serve`.
3. Drive the model picker from `textModelReadiness(_:)` for text models and `modelOptions(for:)` for capability models. Drive diagnostics from `runtimeStatus()` and `resourcePressure()`.
4. On iOS, register embedded GGUF and Apple Foundation Models only. MLX reports itself unsupported; it never fails silently.
5. Existing one-shot code keeps working unchanged, and no longer leaks memory per call.

## 1. Persistent model lifecycle

| | `.oneShot` (default) | `.managed(config)`: use for chat and agents |
|---|---|---|
| Model load | Every call | Once; stays warm until evicted, unloaded or shut down |
| After a call | Everything released (native context, MLX state file, worker) | Returned to the pool, still warm |
| Concurrency | Unbounded; one model copy per call | `maxConcurrentRequests` (default 2), one shared copy per model |
| Prefix (KV) reuse | None | macOS MLX: `live` in the persistent worker. GGUF: opt-in `reusePromptPrefix` |

- **Configuration defaults** (`EshManagedLifecycleConfiguration`):
  - `maxResidentModels` 2 (least recently used is evicted first)
  - `maxConcurrentRequests` 2
  - `idleTimeoutSeconds` 300
  - `memorySafetyReserveGB` 3
  - `memoryBudgetGB` = RAM − reserve
  - `respondsToSystemMemoryPressure` true

  On iOS, use `maxResidentModels: 1` and `maxConcurrentRequests: 1`.
- **Each turn:** send the whole conversation. Requests stay independent; reuse happens below the API.
- **Cancelling:** cancel the consuming task. The concurrency slot is freed and the model stays warm. GGUF also stops during prefill.
- **Switching models:** pin a different id. Active requests are never evicted.
- **After `shutdown()`:** the runtime is finished. Build a new one to continue.

Measured on an M1 Pro (32 GB), 10-turn session:

| Model | SDK managed | `esh serve` | SDK one-shot |
|---|---|---|---|
| MLX Llama-3-8B | 33.8 s; follow-up TTFT 0.63 s | 28.0 s; 0.48 s | 202 s |
| GGUF Qwen2.5-1.5B, managed with `reusePromptPrefix` | 3.55 s | 4.41 s | 21.0 s |

## 2. Supported platforms

| | macOS | iOS |
|---|---|---|
| Embedded GGUF (llama.cpp, in-process, Metal) | ✅ | ✅ |
| Apple Foundation Models | ✅ | ✅ |
| MLX text (persistent Python worker, `live` cache) | ✅ | ❌ Compiles to an unsupported stub |
| `Process`, Python, llama-server | used on macOS only | never |

The iOS `MLXBackend` stub can be registered unconditionally:
- it reports nothing as supported;
- Auto never selects it;
- a pinned MLX model, `stream` or `prewarm` throws `EshRuntimeError.backendUnavailable(.mlx, reason)`;
- `textModelReadiness` reports `unsupportedOnPlatform`.

Builder snippets: [§3 of the full guide](esh-sdk-managed-runtime.md#3-building-the-runtime). In short:
- **macOS:** `EshRuntime.makeDefault(backends:…, lifecycle: .managed())` with `AppleBackend()`, `MLXBackend(bridge:persistent: true)` and `LlamaCppEmbeddedBackend(config:)`
- **iOS:** `makeWithEmbeddedGGUF(config:lifecycle:)`

## 3. Capability reporting

| API | Answers | Studio surface |
|---|---|---|
| `capabilities() -> EshCapabilitySnapshot` | Each backend's `BackendCapabilityReport`, with explicit `unavailableFeatures`, plus Apple Intelligence status | Settings, backend list |
| `textModelReadiness(_:)` | One text model: `resident`, `ready`, `notInstalled`, `unsupportedOnPlatform`, `backendNotWired`, `notReady` or `insufficientMemory`, with a reason and `canRunNow`. Loads nothing | Text model picker |
| `modelOptions(for: CapabilityID)` (#30) | Concrete models for a capability, each with readiness, memory fit, size and a one-line note | Capability model pill |
| `runtimeStatus().backends` | Each wired backend's `BackendLifecycleTraits`: residency, in-process, prefix reuse, context bounded at load, cancels during prefill, iOS support | Diagnostics |

Studio shouldn't hardcode backend behavior. Read it from these.

## 4. Memory management

The SDK guarantees all of the following:
- **Load gate:** every load goes through the live memory check (`ModelLoadSafetyGate`/`MemorySafetyPreflight`). A refusal arrives as `insufficientMemory`.
- **KV-growth guard:** every MLX request runs through the same check `esh serve` uses. GGUF context is capped at load by `contextTokens`; a longer prompt fails with a clear "prompt is N tokens…" error.
- **Pool budget:** least-recently-used idle models are evicted first. Idle models are unloaded after the idle timeout.
- **Memory pressure:** on a warning, idle caches are released. On a critical event, idle models are evicted.
- **Leak fix:** native GGUF contexts are freed deterministically. Memory stays flat over 30 turns (it previously grew by about 60 MB per call).

Studio decides when, using these calls:

| Call | When |
|---|---|
| `prewarm(modelID:)` | A chat opens |
| `unloadIdleRuntimes()` | Before a heavy image or audio job; frees idle text models and capability providers |
| `unload(modelID:)` | The user ejects a model. Throws `UnloadError.modelActive` rather than interrupting a request |
| `resourcePressure()` | Before starting heavy work: memory, free disk on each volume, and a critical flag |
| `shutdown()` | App teardown. Awaited and idempotent |

**Where resident models are listed:**
- **Text models:** `runtimeStatus().pool`, with state, residency, measured memory, load count and cache bytes. It has the same shape as `esh serve`'s `GET /v1/runtime`.
- **Native image tiers:** `residentModels()`.

## 5. Errors to handle

All errors are `EshRuntimeError`, apart from task cancellation:

| Error | What Studio shows |
|---|---|
| `insufficientMemory(modelID:reason:)` | Suggest a smaller model or a shorter conversation |
| `pinnedModelUnavailable` | Not installed or not ready; `textModelReadiness` predicts this |
| `backendUnavailable(kind:reason:)` | Backend not wired, or MLX on iOS; suggest a GGUF build |
| `generationFailed(reason:)` | Includes GGUF context overflow; offer to trim history |
| `noAvailableBackend` | Also thrown after `shutdown()`; rebuild the runtime |
| `CancellationError` | Nothing to show |

## 6. Adoption checklist

- [ ] Bump the esh dependency to a commit or tag that includes `e1d1271`.
- [ ] Build one app-wide runtime with `.managed()`. On macOS register `MLXBackend(persistent: true)`; on iOS use `makeWithEmbeddedGGUF`.
- [ ] Set `LlamaCppConfig(contextTokens:, reusePromptPrefix: true)` for chat.
- [ ] Remove the Studio-side `RuntimeLifecycleManager`, load-gate and growth-check code.
- [ ] Point the text picker at `textModelReadiness` and the capability pill at `modelOptions(for:)`.
- [ ] Add a diagnostics panel fed by `runtimeStatus()` and `resourcePressure()`.
- [ ] Call `prewarm` when a chat opens, `unloadIdleRuntimes` before heavy jobs, and `shutdown` on teardown.
- [ ] Map the errors in §5 to UI.

## 7. Known limits

- **iOS:** build-verified in CI only, with no on-device memory numbers yet. Run `Examples/EshIOSProbe` on a device; it exercises `.managed()`.
- **GGUF requests:** one at a time per loaded model, so chats on the same model queue. `reusePromptPrefix` keeps one cached sequence per model, so two chats alternating on one model evict each other's prefix (still correct, just slower).
- **Memory pressure:** the reactions are unit-tested with injected events. A real system-wide pressure event was not triggered.
- **Apple Foundation Models:** not pooled; the system owns that model.
