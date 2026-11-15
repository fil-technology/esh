# Managed inference through the esh SDK: Studio integration guide

**For:** esh Studio (macOS + iOS) and any app that embeds esh. **Applies to:** the `feat/managed-sdk-runtime` branch (not merged yet).

This replaces §0 and §4.2 of [esh-studio-runtime-readiness.md](esh-studio-runtime-readiness.md): Studio no longer needs to assemble the pooled path itself. Measurements and the GGUF leak investigation are in [docs/research/managed-sdk-runtime-2026-11.md](../research/managed-sdk-runtime-2026-11.md).

## 1. Who owns what

| esh SDK (`EshRuntime`) owns | Studio owns |
|---|---|
| Model loading, reuse, eviction, switching | UI and presentation |
| Memory safety: the load gate, the KV-growth guard, the pool budget, memory-pressure response | Chat history and persistence |
| Prefix (KV) caching and cache budgets | Settings: which model, which lifecycle, limits |
| Concurrency limits and request admission | Deciding when to call `shutdown()` (app teardown) |
| Clean shutdown of workers and native contexts | Showing readiness and errors the SDK reports |

**Studio must not build a `RuntimeLifecycleManager`, a load gate or a growth guard of its own.** Pick a lifecycle when building the `EshRuntime`; the SDK does the rest.

## 2. The two lifecycles

```swift
public enum EshRuntimeLifecycle: Sendable {
    case oneShot                                              // default: load per call, release at the end
    case managed(EshManagedLifecycleConfiguration = .init())  // warm pool, shared with `esh serve`'s design
}
```

| | `.oneShot` (default) | `.managed()` |
|---|---|---|
| Model load | Every call | Once; reused until evicted, unloaded or shut down |
| After the call | Runtime released: native context freed, MLX state file and KV sidecar removed, worker stopped | Stays warm in the pool |
| Use for | Occasional calls, tools, CLIs | Chat, agents, anything multi-turn |
| MLX prefix reuse (macOS) | None across calls | `live` in the persistent worker (default rule), `tokens` otherwise |
| Concurrency | Unbounded; each call loads its own copy (memory multiplies) | Bounded by `maxConcurrentRequests`; one shared copy per model |
| Memory-pressure response | Nothing resident to release | Idle caches released on warning; idle models evicted on critical |
| `shutdown()` | Releases capability providers only | Unloads every model, awaited; refuses new text work afterwards |

Before this branch, one-shot calls **never released their runtime**: every embedded-GGUF call leaked a llama context (≈60 MB per call with a 0.5B model) and every MLX call left a state file on disk. That is fixed for all existing consumers with no API change.

### Configuration

```swift
public struct EshManagedLifecycleConfiguration: Sendable, Equatable {
    public var maxResidentModels: Int                 // default 2 (LRU beyond)
    public var maxConcurrentRequests: Int             // default 2 (interactive before background)
    public var idleTimeoutSeconds: Double             // default 300 (idle sweep unloads)
    public var memoryBudgetGB: Double?                // default: physical RAM − memorySafetyReserveGB
    public var memorySafetyReserveGB: Double          // default 3
    public var respondsToSystemMemoryPressure: Bool   // default true
}
```

None of these can bypass memory safety: every load still goes through the live load gate, and every MLX request through the KV-growth guard.

## 3. Building the runtime

### macOS (MLX + embedded GGUF + Apple Foundation Models)

```swift
import EshRuntime
import EshLlamaCpp
import EshMLXText
import EshMacCapabilities

let root = PersistenceRoot.default()
// esh's managed Python venv + the shipped bridge (no user-configured Python).
let mlxPaths = MLXTextRuntimeProvisioner.resolvedPaths(root: root)
let bridge = MLXBridge(configuration: MLXBridgeConfiguration(
    pythonExecutablePath: mlxPaths?.pythonExecutablePath, helperScriptPath: mlxPaths?.bridgeScriptPath))

let runtime = await EshRuntime.makeDefault(
    backends: [
        .apple: AppleBackend(),
        .mlx: MLXBackend(bridge: bridge, persistent: true),   // persistent = weights-resident worker
        .gguf: LlamaCppEmbeddedBackend(config: LlamaCppConfig(contextTokens: 8192, reusePromptPrefix: true)),
    ],
    root: root,
    installProvider: FileInstallProvider(root: root),
    localModelManager: LocalModelManager(root: root),
    lifecycle: .managed())
```

- Use `persistent: true` with `.managed()`; the pool owns each worker and stops it on eviction or shutdown. With `.oneShot`, use `persistent: false`.
- `MLXTextRuntimeProvisioner.probe(root:)` / `ensure(...)` tell you whether the MLX text runtime is installed and install it.

### iOS (embedded GGUF + Apple Foundation Models)

```swift
import EshRuntime
import EshLlamaCpp

let runtime = await EshRuntime.makeWithEmbeddedGGUF(
    config: LlamaCppConfig(contextTokens: 4096, reusePromptPrefix: true),
    lifecycle: .managed(.init(maxResidentModels: 1, maxConcurrentRequests: 1)))
```

- No `Process`, no Python, no localhost server: llama.cpp runs in-process on Metal.
- `EshMLXText` compiles on iOS. #29 makes the macOS sources `#if os(macOS)`, and this branch adds an `MLXBackend` stub so shared code can register it unconditionally; code guarded with `#if os(macOS)` keeps working. The stub is backed by the portable, macOS-tested `UnsupportedPlatformBackend`, so it never advertises or runs anything:
  - **Capability report:** not ready, no supported features, every feature listed as unavailable with the reason.
  - **Auto:** never selects it.
  - **Pinned MLX model, `prewarm` or `stream`:** fail with `EshRuntimeError.backendUnavailable(.mlx, reason)`.
  - **Direct `loadRuntime`:** throws `BackendUnsupportedOnPlatformError`.
  - **`textModelReadiness`:** reports `unsupportedOnPlatform`.
- MLX prefix caching, `live` caching and the Python-side KV guard do not exist on iOS. Embedded GGUF's context is bounded at load by `contextTokens`.
- **`reusePromptPrefix: true`** (opt-in, off by default) keeps the common token prefix of the previous request in the loaded context and decodes only the new tokens: the in-process equivalent of llama-server's prompt cache. Use it with `.managed()` (a one-shot runtime is freed after each call, so there is nothing to reuse). It holds **one** cached sequence per loaded model: two chats alternating on the same model evict each other's prefix (still correct, just slower).
- The same `LlamaCppEmbeddedBackend` setup works on macOS (§3, macOS block).

## 4. Using it

Requests are unchanged:

```swift
for try await event in runtime.stream(EshGenerationRequest(messages: chat, constraints: .pinned(modelID),
                                                           config: GenerationConfig(maxTokens: 512))) {
    switch event {
    case .token(let t): append(t)
    case .reasoningDelta(let r): appendReasoning(r)
    case .completed(let result): finish(result)   // the model is already released back to the pool here
    case .toolCall: break
    }
}
```

- **Send the whole conversation every turn.** Requests are independent (session isolation). Reuse happens below the API: the pool keeps the model loaded, and on macOS MLX the persistent worker matches the conversation's prefix by content.
- **Cancellation:** cancel the consuming task. Generation stops (embedded GGUF also stops during prefill), the concurrency slot is freed and the model stays warm.
- **Switching models:** pin a different id. Up to `maxResidentModels` stay warm; beyond that the least recently used idle model is unloaded first. Active requests are never evicted.

### Lifecycle and status APIs

| API | Purpose |
|---|---|
| `runtimeStatus() async -> EshRuntimeStatus` | Mode, shutdown flag, the pool status (residents with state, residency, estimated and measured memory, load count, active requests, prefix-cache mode, resident cache bytes; plus budget and limits; the same `RuntimePoolStatus` as `esh serve`'s `GET /v1/runtime`), and each wired backend's `BackendLifecycleTraits` |
| `textModelReadiness(_ modelID) async -> EshTextModelReadiness` | Whether a text model can run now: `resident`, `ready`, `notInstalled`, `unsupportedOnPlatform`, `backendNotWired`, `notReady`, `insufficientMemory`, with a reason. Loads nothing. Use it for the model picker |
| `prewarm(modelID:) async throws` | Load ahead of the first request (e.g. when a chat opens). No-op for one-shot and Apple FM |
| `unload(modelID:) async throws` | Unload an idle model now. Throws `UnloadError.modelActive` rather than interrupt a request |
| `unloadIdleRuntimes() async` | Release every idle model and provider (e.g. before a heavy image job) |
| `shutdown() async` | Release everything and wait until it is gone. Call on app teardown. Idempotent |
| `capabilities()` | Unchanged: per-backend `BackendCapabilityReport` with explicit `unavailableFeatures` |

### `BackendLifecycleTraits` (per wired backend)

| Trait | Embedded GGUF | MLX persistent | MLX one-shot | Apple FM |
|---|---|---|---|---|
| `residency` | weights-resident | weights-resident | handle-cached | handle-cached (system) |
| `inProcess` | yes | no (Python worker) | no | yes |
| `prefixReuse` | none, or resident-tokens with `reusePromptPrefix` | live (default) / persisted-tokens | persisted-tokens | system-managed |
| `contextBoundedAtLoad` | yes (`n_ctx`) | no (growth guard) | no (growth guard) | yes |
| `cancelsDuringPrefill` | yes | no | no | no |
| `serializesRequestsPerModel` | yes | yes | yes | no |
| `supportsIOS` | yes | no | no | yes |

### Errors Studio should handle

All failures are `EshRuntimeError`; Studio never needs to know pool internals.

| Error | When | What to show |
|---|---|---|
| `insufficientMemory(modelID:reason:)` | Load refused by the live gate, or a request's context would need too much KV memory | The reason; suggest a smaller model or a shorter conversation |
| `pinnedModelUnavailable` | Not installed, or not ready | The reason (`textModelReadiness` predicts it) |
| `backendUnavailable(kind:reason:)` | The model's backend isn't wired, or can't run on this platform (MLX on iOS) | The reason, and suggest a GGUF build of the model on iOS |
| `generationFailed(reason:)` | Includes an embedded-GGUF prompt longer than `contextTokens` ("The prompt is N tokens but the model's context window is M tokens…") | Offer to trim history |
| `noAvailableBackend` | Also after `shutdown()` | Rebuild the runtime |
| `CancellationError` | The consuming task was cancelled | Nothing |

## 5. Migrating existing Studio code

1. **No change is required to keep working.** Existing `EshRuntime()`, `withEmbeddedGGUF(...)` and `makeDefault(...)` callers keep the one-shot behavior, now without the leak.
2. **For chat, opt in to `.managed()`** in the runtime builder (§3), keep one `EshRuntime` per app (not per chat), and call `shutdown()` on teardown.
3. **Delete any Studio-side pool**: a `RuntimeLifecycleManager`, a hand-rolled `loadRuntimeGuarded` path or a growth check. The SDK now does this.
4. **Model picker:** replace ad-hoc checks with `textModelReadiness(_:)`; show `runtimeStatus().pool` in a diagnostics panel.
5. **macOS MLX:** register `MLXBackend(bridge:persistent: true)` with `.managed()`. Don't register a persistent backend on a one-shot runtime (each call would start and stop a worker).
6. **Settings:** expose `maxResidentModels`, `idleTimeoutSeconds` and `contextTokens` if useful; leave the memory reserve at its default.

## 6. Limitations

- **Embedded GGUF prefix reuse is opt-in** (`reusePromptPrefix`). Without it every turn re-prefills the whole conversation, so time to first token grows with the conversation. With it, one cached sequence per loaded model.
- **One request at a time per loaded GGUF model**, and a request occupies a cooperative-pool thread while it decodes. Concurrent chats on the same model queue.
- **iOS is build-verified in CI** (EshCore, EshRuntime, EshMLXText stub, the probe and clean-room apps). On-device memory numbers are from macOS; iOS runtime numbers need a device run of `Examples/EshIOSProbe` (it now also exercises `.managed()`).
- **Memory pressure:** the pool subscribes to system events, but a real system-wide pressure event was not triggered in testing (same as for `esh serve`); the reactions are unit-tested with injected events.
- **Apple Foundation Models are not pooled**: the system owns that model.
- **`shutdown()` is final** for a managed runtime; build a new one to continue.
