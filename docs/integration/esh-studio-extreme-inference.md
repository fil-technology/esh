# esh ⇄ Studio integration contract — extreme local inference

Audience: the **esh Studio** agent. This documents the **existing public esh APIs** Studio uses to discover, run,
and manage the two validated large-model configurations. esh owns execution; Studio requests capabilities. All
types are in `EshCore` / `EshRuntime` (portable, iOS + macOS). **No Studio-specific code lives in esh.**

Status: research branch `research/extreme-local-inference` (not yet merged). Snapshot of findings:
`docs/research/extreme-local-inference.md` + `benchmarks/`.

---

# VALIDATED RUNTIME CONTRACT (2026-10-12, post mlx-swift 0.32.3 migration)

> This section is the **authoritative, real-weight-verified** contract for the Studio agent. Where it differs
> from the older sections below, this section wins. Every item is tagged **[VALIDATED]** (exercised on-device
> with real weights on an M1 Pro / 32 GB this date), **[DETERMINISTIC]** (covered by unit tests, not a real
> model run), or **[PROPOSED]** (not implemented — do not integrate as if present). Branch:
> `migration/mlx-swift-0.31`. Nothing here is pushed/tagged/merged yet.

## Runtime architecture (so Studio does not guess)
- **Text LLM (MLX)** runs in a **Python `mlx-serve` worker** (`mlx_lm`), spawned by esh. It is NOT the native
  Swift mlx-swift stack. The worker's Python must have `mlx_lm` installed; esh resolves it via `ESH_PYTHON`
  (or a repo `.venv`, or a bundled python), else falls back to `/usr/bin/python3` which has no mlx and fails.
  **[VALIDATED]**
- **Native Swift mlx-swift** powers **vision** (`EshVision` → mlx-swift-lm MLXVLM), **image generate/edit/restyle**
  (`EshImageGen` → mlx-swift StableDiffusion / InstructPix2Pix / PhotoMaker / SDXL-Turbo), and **audio/TTS**
  (`TTSMLX` / `mlx-audio-swift`). These are in-process, no Python. **[VALIDATED]**
- **GGUF** (text) runs through the embedded `EshLlamaCpp` backend (vendored llama.cpp), unaffected by this
  migration. **[VALIDATED earlier]**
- esh owns inference; Ashex/Studio owns agent orchestration. No second inference runtime is introduced.

## 1. Model discovery
- **Catalog presets:** `RecommendedModelRegistry().list()` / `.recommend(...)` → `[RecommendedModel]`
  (`id`, `repoID`, `backend`, `quantization`, `estimatedMemoryGB`, `measuredPeakMemoryGB?`, `status`, …). **[VALIDATED]**
- **Installed models:** `await runtime.localModels()` → `[LocalModelStatus]`; CLI `esh model list`. **[VALIDATED]**
- **Catalog id vs installed id:** a catalog preset carries a catalog `id` (e.g. `qwen-3-30b-a3b-mlx-4bit`). An
  *installed* model's id is whatever it was imported/installed as (e.g. `qwen3-30b-a3b-4bit`) — it is the HF repo
  lowercased with `/`→`--` for `esh model install <repo>`, or the `--id` given to `esh model import`. **These are
  not interchangeable:** selection (§3) matches against *installed* ids/repos/display-names, not catalog ids.
  Studio must select by an **installed** id (from `localModels()`), not a catalog id. **[VALIDATED]**

## 2. Model install / import (no duplicate downloads)
- `esh model install <repo>` downloads into esh's own store (`<assetsRoot>/models/installs/<id>/`). **[VALIDATED]**
- `esh model import <path> [--id <id>]` registers already-downloaded weights. It now understands a **Hugging Face
  cache snapshot** (weights are symlinks into a shared `blobs/` store): `detect`/`import` resolve symlinks and
  copy the real content, leaving the shared cache intact — so a model already in the HF cache is registered with
  **no network re-download**. It still copies into the store (esh installs are self-contained), so the store copy
  is a local duplicate of the cache copy; esh never deletes the cache. **[VALIDATED]** (used to register the 30B).
- `runtime.install(_:)` / `runtime.installStream(_:)` → `AsyncThrowingStream<DownloadState,Error>`;
  `ModelDownloadHandle.pause()/resume()/cancel()`. **[DETERMINISTIC]**
- Assets live on the configured volume (external SSD here) via `storage.json` / `ESH_ASSETS_HOME`; esh gates on
  volume availability and fails cleanly if it is missing rather than writing to the internal disk. **[VALIDATED]**

## 3. Explicit model selection — EXACT, never substituted
- `esh infer --model <id>` / an `ExternalInferenceRequest.model` / `EshConstraints(pinnedModelID:)` is an
  **exact selection**: esh runs that model or returns a clear error. It **no longer silently substitutes** a
  different installed model (a prior defect ran an 8B GGUF for a 30B request). A default is chosen only when **no**
  model is requested. Unknown explicit model → `StoreError.notFound("Requested model '…' is not installed …")`.
  The result echoes the actual `modelID` + `backend` that ran — Studio should assert they match the request. **[VALIDATED]**
- Example (verified): `esh infer --model qwen3-30b-a3b-4bit …` → result `backend="mlx"`,
  `modelID="qwen3-30b-a3b-4bit"`, real tokens @ ~38 tok/s, peak ~17.2 GB.

## 4. Backend selection
- The backend is a property of the installed model (`RecommendedModel.backend` / the install's spec):
  `.mlx` (text via Python mlx-serve), `.gguf` (embedded llama.cpp), `.apple` (Apple FM). Studio does not pick a
  backend directly; it selects a model and reads the `backend` esh reports in the result/profile. **[VALIDATED]**

## 5. Streaming, cancellation, bounded generation
- **Streaming:** `runtime.stream(_:)` → `AsyncThrowingStream` of `.token`/`.textDelta`/`.reasoningDelta`/
  `.progress`/`.artifactProduced`/`.completed`. **[VALIDATED]** (text, vision, image).
- **Cancellation:** cancel the consuming `Task` (or stop iterating); esh stops generation promptly. Verified:
  VLM cancel ~0.4 s, image-gen/edit cancel ~0.5 s. **[VALIDATED]**
- **Bounded generation:** the VLM understand path honours a `maxTokens` request option and applies a safe default
  (512) when none is given, so a model cannot run away into unbounded/degenerate output. Image gen/edit honour
  `steps`/`width`/`height`/`seed`. **[VALIDATED]**

## 6. Memory safety (errors Studio must surface)
- Every load runs a live preflight. If a model cannot run safely it is **refused before loading** with a typed
  gate, e.g. `.insufficientMemory(modelID:reason:)` (facade) or a `CapabilityResourceGate`
  (`reason`, `requiredGB`, `availableGB`) on the capability path. The reason is user-ready. **[VALIDATED]** —
  on-device, `image.edit` (≈12 GB peak) was correctly **refused** when only ~7.6 GB system-volume/swap headroom
  was free, and **permitted** after headroom was freed. The guard keys on **system-volume/swap headroom**, not
  just free RAM (macOS can swap; the internal volume being near-full is the real ceiling).
- Studio must surface the reason and offer a smaller model or a retry after freeing space; never auto-substitute.

## 7. Model lifecycle — NO warm-pool on the inference path (today)
- Text `stream()`/`generate()` and the native capability providers **load per call and release at end of call.**
  **`residentModels()` is empty after a turn and `unload(modelID:)` throws for a chat model.** Repeated requests
  reload the weights. **Do not assume keep-warm.** `residentModels()`/`unload()` and `RuntimeLifecycleManager`
  exist but are **[PROPOSED]** for the inference path — a scoped follow-up would route loads through the warm
  pool. Studio must treat warm-pool reuse as **not available**. (In-process native engines DO reuse within a
  single process for back-to-back calls — e.g. the VLM/image engines were ~100× faster on the 2nd call in one
  process — but that is per-process, not the cross-request warm pool.)

## 8. Capabilities — validated APIs + the models used
| Capability | Facade | Backend | Validated model | Status |
|---|---|---|---|---|
| Text chat/generate (MLX) | `stream`/`generate`/`esh infer` | `.mlx` (Python mlx-serve) | `qwen3-30b-a3b-4bit` | **[VALIDATED]** |
| Text chat (GGUF) | same | `.gguf` (embedded) | llama-3-8b / Qwen3-Next-80B IQ2 | **[VALIDATED earlier]** |
| Image understanding (VLM) | `EshRuntime.makeWithVision()` → `.imageUnderstand` | `.mlx` native | `mlx-community/Qwen2-VL-2B-Instruct-4bit` | **[VALIDATED]** |
| Image generation | `makeWithImageGen(selfHosted:)` → `.imageGenerate` | `.mlx` native | SD 2.1 base (self-hosted) | **[VALIDATED]** |
| Image edit (instruct) | `makeWithImageEdit()` → `.imageEdit` | `.mlx` native | `timbrooks/instruct-pix2pix` (self-hosted) | **[VALIDATED]** |
| Image edit (identity) | PhotoMaker tier → `.imageEdit` | `.mlx` native | PhotoMaker + SDXL | **[DETERMINISTIC]** |
| Image restyle | `makeWithImageRestyle()` → `.imageRestyle` | `.mlx` native | SDXL-Turbo | **[DETERMINISTIC]** |
| Audio / TTS | `esh audio speak` / TTS facade | `.mlx` native (TTSMLX) | `mlx-community/Soprano-80M-bf16` | **[VALIDATED]** |

The `esh image edit` **CLI subcommand** is a *separate* MFLUX/Python path (`ImageEditBackend` =
qwen-edit/flux2-klein/kontext) — distinct from the native `.imageEdit` capability above. Studio should drive the
native capability via the facade, not the CLI subcommand, when it wants the in-process native tier.

## 9. Known limitations (read before integrating)
- **Warm-pool reuse is not available** on the inference path (§7). **[do not claim it]**
- **MLX text needs `mlx_lm` in the worker's Python** (§ arch). If absent, text MLX fails; provision it or set
  `ESH_PYTHON`. GGUF text and all native-Swift capabilities do not need Python.
- **4-bit VLM quality:** a 4-bit VLM can emit degenerate/repetitive text on trivial synthetic images and may not
  put multiple attributes in one short answer. Bounded generation prevents runaway; Studio should prefer focused
  prompts and a sensible `maxTokens`.
- **Reproducible packaging** still uses a local path override for mlx-swift (see the migration audit); a
  push-free fresh-checkout build is pending fork publication. Treat the exact dependency tags as **[PROPOSED]**
  until released.
- **GGUF in-process backend** aborts at *process exit* unless the clean-shutdown fix is present; that fix lives on
  `fix/gguf-metal-shutdown` and is not yet merged here.

---

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

---

# RELEASE REFERENCE (stable, reproducible) — for Studio integration

**esh tag:** `v2.4.0-rc.35` on `fil-technology/esh` (branch `migration/mlx-swift-0.31`). This is the stable,
reproducible reference: it resolves and builds from immutable dependency tags with **no local path
overrides, no SwiftPM mirror, and no uncommitted source dependencies**. Verified by a clean fresh-checkout
build (root + macOS), CLI launch, and 520/520 regression.

**Pinned dependency graph (all immutable):**

| Package | Reference |
|---|---|
| ml-explore/mlx-swift | `0.32.3` (upstream; no fork — bg-safety handled by the 0.32.x refactor) |
| ml-explore/mlx-swift-lm | `3.32.3` |
| huggingface/swift-transformers | `1.3.5` (resolved; pinned `.upToNextMinor(1.3.0)`) |
| huggingface/swift-huggingface | `1.0.0` (resolved; pinned `0.8.1..<2.0.0`) |
| fil-technology/mlx-swift-examples | `0.1.0-mlx0.32` (fork of upstream 378f2449; mlx-swift range widened to admit 0.32.x) |
| fil-technology/mlx-swift-image-edit | `0.2.1-mlx0.32` |
| fil-technology/TTSMLX (macOS only) | `0.3.7` → fil-technology/mlx-audio-swift `0.1.10-tts.1` |

**Included in this release:** the mlx-swift 0.29→0.32.3 migration, the native-capability validations
(vision/image-gen/image-edit/audio), exact model selection, bounded VLM generation, and the embedded-GGUF
clean-shutdown fix (`GGML_METAL_NO_RESIDENCY=1`, cherry-picked isolated — no research history).

**iOS background safety:** PENDING device validation (see docs/research/ios-background-safety-mlx-0.32.md).
Does not affect macOS Studio integration.
