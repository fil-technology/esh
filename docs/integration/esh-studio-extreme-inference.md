# esh ⇄ Studio integration contract — extreme local inference

Audience: the **esh Studio** agent. This documents the **existing public esh APIs** Studio uses to discover, run,
and manage the two validated large-model configurations. esh owns execution; Studio requests capabilities. All
types are in `EshCore` / `EshRuntime` (portable, iOS + macOS). **No Studio-specific code lives in esh.**

Status: research branch `research/extreme-local-inference` (not yet merged). Snapshot of findings:
`docs/research/extreme-local-inference.md` + `benchmarks/`.

## The two configurations

| Model id (catalog) | Backend | Quant | Measured peak | Speed (M1 Pro) | Status |
|---|---|---|---|---|---|
| `qwen-3-30b-a3b-mlx-4bit` | `.mlx` | 4-bit | 18.0 GB | ~28–40 tok/s | experimental (recommended default) |
| `qwen-3-next-80b-a3b-iq2xs-gguf` | `.gguf` | IQ2_XS | 22.0 GB | ~15–21 tok/s | experimental (opt-in large model) |

Both are MoE (~3B active/token). Quality: both pass esh's objective suites (9/9 smoke, 16/16 hard); **no measured
quality advantage for the 80B** — do not present it as higher-quality. 30B is the default; 80B is opt-in.

## 1. Model discovery

- **Catalog (recommended presets):** `RecommendedModelRegistry()` →
  `.list()` / `.recommend(useCase:host:limit:includeExperimental:)` → `[RecommendedModel]`.
  Key fields (`EshCore/Domain/RecommendedModel.swift`): `id`, `repoID`, `backend: BackendKind` (`.mlx`/`.gguf`/
  `.apple`), `quantization`, `estimatedMemoryGB`, `measuredPeakMemoryGB: Double?` (MEASURED runtime peak when
  known — prefer it for UI memory hints), `totalDiskSizeGB`, `contextWindow`, `capabilities`, `status`
  (`.recommended`/`.experimental`/`.legacy`/`.incompatible`), `tags`, `summary`. The two models are `.experimental`.
- **Installed models:** `await runtime.localModels()` → `[LocalModelStatus]` (what is actually on disk/runnable).
- **Model id semantics:** an installed model's id is the HF repo lowercased with `/`→`--` (e.g.
  `mlx-community--qwen3-30b-a3b-4bit`); the runtime also resolves a model by its HF repo id or display name.
  For the catalog presets above, Studio pins the catalog `id`.

## 2. Model execution

Facade: `public actor EshRuntime` (`EshRuntime/EshRuntime.swift`).

- **Run (buffered):** `try await runtime.generate(EshGenerationRequest) -> EshGenerationResult`.
- **Run (streaming):** `runtime.stream(EshGenerationRequest) -> AsyncThrowingStream<EshGenerationEvent, Error>`.
  Events: `.token(String)`, `.reasoningDelta(String)`, `.completed(EshGenerationResult)`.
- **Request:** `EshGenerationRequest(messages: [Message], constraints: EshConstraints, config: GenerationConfig,
  responseFormat:?, tools:?, toolChoice:?)`. Pin a model with `EshConstraints(localOnly: true, pinnedModelID: id)`
  — a pin is **never** substituted. `GenerationConfig(maxTokens:temperature:topP:enableThinking:...)`.
- **Result:** `EshGenerationResult(text, selection: EshSelection, metrics, reasoning?)`.

## 3. Cancellation + errors

- **Cancellation:** cancel the `Task` consuming the stream (or stop iterating). The stream's `onTermination`
  cancels the backend generate; `Task.checkCancellation()` runs each token. Validated: cancels mid-stream.
- **Errors:** `EshRuntimeError` (typed, `LocalizedError`): `.noAvailableBackend`, `.pinnedModelUnavailable`,
  `.backendUnavailable`, `.localOnlyViolation`, `.unsupportedDevice`, `.modelLoadFailed`, `.generationFailed`,
  and **`.insufficientMemory(modelID:reason:)`** — the live memory-safety rejection (see §5). Surface
  `error.errorDescription` to the user; `.insufficientMemory.reason` is already user-facing and actionable.

## 4. Model lifecycle

- **Install / download:** `runtime.installStream(_:)` → `AsyncThrowingStream<DownloadState,Error>` (progress) or
  `runtime.install(_:)`; `ModelDownloadHandle` supports `pause()`/`resume()`/`cancel()`. The CLI equivalent is
  `esh model import <path>` (register already-downloaded weights without re-downloading) / `esh model install
  <repo>`. esh keeps its own model store under `<assetsRoot>/models/installs/<id>/` — it does NOT read a generic
  HF cache for chat models.
- **Resident reporting / unload:** `await runtime.residentModels()` and `try await runtime.unload(modelID:)`.
  **⚠ FINDING (contract-relevant):** today the text `stream()`/`generate()` path loads a runtime **per call** and
  releases it when the call ends — it does **not** register into the warm-pool that `residentModels()`/`unload()`
  manage. So `residentModels()` is empty after a chat turn, `unload()` of a chat model throws
  `UnloadError.unknownModel`, and **repeated requests reload the weights each time** (expensive for a 22 GB
  model). Studio must not assume keep-warm today. A scoped follow-up (see §7) adds warm-pool reuse.
- **Model switching:** issue a new request pinned to the other `id`. (With per-call loading there is no explicit
  unload needed; with the warm-pool follow-up, switching will evict per the memory guard.)
- **Memory-pressure handling:** the live preflight (§5) gates each load; `RuntimePressure`/`HostResourceProbe`
  provide signals.

## 5. Model Fit + memory safety

- **Pre-download fit:** `ModelFitService().assess(recommendedModel:contextTokens:host:root:) -> ModelFitAssessment`
  (`fitClass`: comfortable/fits/tight/unlikely/unsupported/unknown, `estimatedPeakMemoryGB`, `reasons`). Prefers a
  MEASURED `measuredPeakMemoryGB` over the param-count heuristic; understands sub-4-bit IQ quants. Disk size and
  runtime memory are distinct fields.
- **Live load-time safety (automatic):** every load runs through `MemorySafetyPreflight` inside
  `EshRuntime.loadRuntime`. It sizes the model (catalog measured peak, else on-disk weight bytes) and judges it
  against a live snapshot (available memory + swap/disk headroom). If unsafe it throws
  `.insufficientMemory(modelID:reason:)` — e.g. *"needs ~22 GB but only ~13 GB is free now and the internal disk
  has ~9.2 GB for swap; close apps or free disk space, then retry (no reboot required)."* **Validated end-to-end**
  through the facade with the real 80B. A reboot is never required; freeing memory and retrying resolves it.
- **Recommended fallback:** on `.insufficientMemory`, Studio should surface the reason and offer the smaller
  model (the 30B) or a retry after freeing memory — do not auto-substitute a pinned model (esh won't).

## 6. Integration examples (compile against the real public API)

```swift
import EshCore
import EshRuntime

// Discover the recommended presets (filter to runnable backends in your UI).
let catalog = RecommendedModelRegistry().list()   // [RecommendedModel]
let big = catalog.first { $0.id == "qwen-3-next-80b-a3b-iq2xs-gguf" }
// big?.measuredPeakMemoryGB == 22.0 ; big?.status == .experimental

// Run the default 30B, streaming, pinned.
func runDefault(_ runtime: EshRuntime) async {
    let req = EshGenerationRequest(
        messages: [Message(role: .user, text: "Refactor this Swift function…")],
        constraints: EshConstraints(localOnly: true, pinnedModelID: "qwen-3-30b-a3b-mlx-4bit"),
        config: GenerationConfig(maxTokens: 512))
    do {
        for try await event in runtime.stream(req) {
            if case let .token(t) = event { print(t, terminator: "") }
        }
    } catch let e as EshRuntimeError {
        // .insufficientMemory carries a user-ready reason; others via errorDescription.
        print("esh error:", e.errorDescription ?? "\(e)")
    } catch { /* cancellation etc. */ }
}

// Cancellation: cancel the consuming task.
func runCancellable(_ runtime: EshRuntime, req: EshGenerationRequest) -> Task<Void, Never> {
    Task { for try? await _ in runtime.stream(req) { if Task.isCancelled { break } } }
}
```

(These use only existing public symbols; no APIs were invented. The GGUF backend needs a `llama-server`
reachable — `brew install llama.cpp` or `ESH_LLAMA_CPP_SERVER` — on macOS; the portable in-process GGUF backend
is wired via `EshRuntime.withEmbeddedGGUF(root:)`.)

## 7. Compatibility + known limitations (read before integrating)

1. **esh version:** integrate against the merged tag of `research/extreme-local-inference` (TBD on merge). The
   two catalog ids above and `RecommendedModel.measuredPeakMemoryGB` + `EshRuntimeError.insufficientMemory` are
   the new public surface.
2. **macOS MLX path blocked by a dependency migration:** the `macos` package (the `esh` CLI + macOS
   `MLXBackend` + macOS `LlamaCppBackend` server) does not build — `TTSMLX` (≥0.3.3, required for on-device
   audio) hard-depends on `mlx-swift ≥0.30.6`, while the root graph is locked at `0.29.x` by `mlx-swift-examples`
   2.29.1 + `mlx-swift-image-edit` 0.2.0. **There is no small pin tweak** — resolving it is a coordinated
   `mlx-swift 0.29→0.31.x` migration (bump mlx-swift + mlx-swift-examples→main + swift-transformers→1.3, switch
   `mlx-swift-image-edit` to a 0.31-compatible build, and move `EshVision` out of root). A proven-but-incomplete
   config exists on branch `spike/mlx-swift-0.31-flux2`. **Until done, the 30B (MLX) runs only via the raw mlx-lm
   engine, not through the macOS runtime.** Scoped follow-up: ClickUp `z8xxqw8y07` #1.
3. **GGUF 80B — VALIDATED through the in-process backend.** The vendored `esh_llama.xcframework` **does** support
   Qwen3-Next (`qwen3next.cpp`, `llama_model_qwen3next`, gated-delta-net kernels, QWEN3NEXT-MTP). The 80B
   IQ2_XS loaded and streamed through `EshRuntime` + `LlamaCppEmbeddedBackend` at **~25.8 tok/s** (`general.
   architecture = qwen3next`, 843 tensors), with the live memory gate correctly permitting/refusing by live
   headroom. The macOS `LlamaCppBackend` (llama-server) is blocked only by #2's build conflict (the raw server,
   b8660, also runs the 80B). No second GGUF engine introduced.
4. **Warm-pool reuse (efficiency):** chat `stream()` reloads weights per request today (see §4). **Scoped
   follow-up (ClickUp `z8xxqw8y07` #3): route load through `RuntimeLifecycleManager` so repeated requests reuse a
   resident runtime**, preserving the memory guard + `unload()`.
5. **Native shutdown crash (not benign):** the in-process GGUF backend aborts at **process exit** via
   `ggml-metal-device.m:1025 GGML_ASSERT([rsets->data count] == 0)` → `ggml_metal_device_free` →
   `__cxa_finalize`. Root cause: the ggml-metal **residency-set keep-alive (180 s)** holds Metal buffers resident,
   so the global device destructor finds a non-empty residency set at exit. It occurs **only at process
   termination, after inference completes** (results unaffected, reproduces with any GGUF model incl. a 1.5B), and
   is in the **vendored llama.cpp build** — the fix is a rebuilt `esh_llama.xcframework` (disable/flush the
   residency-set keep-alive on teardown). Scoped follow-up: ClickUp `z8xxqw8y07` #4. Studio should not treat
   process exit as clean until this lands.
6. **Memory reality on 32 GB:** the 80B is swap-safe only with real headroom; the live preflight enforces this
   and will reject when the machine is busy. Studio should expect and surface `.insufficientMemory`.

## Recommended integration sequence for Studio

1. Show the catalog (30B default, 80B opt-in/experimental) with `measuredPeakMemoryGB` as the memory hint.
2. Install/import via `installStream` (progress UI).
3. Run via `stream()` pinned to the id; render `.token`; handle `.insufficientMemory` with the reason + offer the
   smaller model.
4. Treat `unload()`/`residentModels()` as warm-pool APIs that are not yet wired to chat (follow-up #4).
5. For the 30B specifically, wait for follow-up #2 (mlx-swift conflict) before relying on the macOS MLX backend.
