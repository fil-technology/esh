# esh/Studio integration plan — resident research models (Priority 4)

Goal: expose the two validated models through esh's **existing** architecture as an **additive, experimental**
layer — no parallel runtime, no changes to MLX/GGUF execution paths (per the ClickUp task's architectural
constraint). Models: Qwen3-30B-A3B (MLX 4-bit) and Qwen3-Next-80B-A3B (GGUF IQ2_XS).

## How esh already runs local LLMs (map; file:line)

- **Backends (unchanged, reused):** `InferenceBackend` → `BackendRuntime` streaming contract
  (`Sources/EshCore/Protocols/InferenceBackend.swift:3`, `BackendRuntime.swift:151`). GGUF via
  `LlamaCppBackend` (llama-server, `macos/Sources/EshMacRuntime/Backends/GGUF/LlamaCppBackend.swift:4`) and
  in-process `LlamaCppEmbeddedBackend` (`Sources/EshLlamaCpp/…:41`, iOS). MLX text via `MLXBackend`
  (`macos/Sources/EshMacRuntime/Backends/MLX/MLXBackend.swift:4`, mlx-lm bridge). Registry:
  `InferenceBackendRegistry.macOS()` wires `{.mlx, .gguf, .apple}`. **Both target models run on these as-is.**
- **Catalog:** `RecommendedModelRegistry.defaultModels` (`Sources/EshCore/Services/RecommendedModelRegistry.swift:132`)
  of `RecommendedModel` (`Sources/EshCore/Domain/RecommendedModel.swift:3`). `backend:` picks `.mlx`/`.gguf`.
- **Fit / `--best`:** `ModelFitService` (`Sources/EshCore/Services/ModelFitService.swift`) +
  `ModelRecommendationService` + `RecommendedModelRegistry.recommend(host:)` gate on `host.safeBudgetGB`
  (= total − max(3, 20%)). `esh model recommended --best-for-this-mac` ranks largest-footprint-within-budget.
- **Lifecycle/guards:** `RuntimeLifecycleManager` (warm pool, `usableBudgetGB`, LRU eviction),
  `RuntimePressure`, `ModelDownloadHandle` (pause/resume/cancel), HF install with GGUF variant selection
  (`HuggingFaceModelDownloader.selectGGUFFiles`, handles split shards).
- **Streaming/cancellation:** `EshRuntime.stream(_:)` (`Sources/EshRuntime/EshRuntime.swift:437`) →
  `runtime.generate` with `Task.checkCancellation()` + `onTermination → task.cancel()`.
- **Studio surface (public facade):** `EshRuntime.generate/stream`, `EshConstraints.pinnedModelID` (how Studio
  pins a model), `localModels()`, `installStream(_:)`, `capabilities()`, `plan/planAuto`.

## Implemented now (this branch — additive, fit-layer + catalog only)

1. **Two `RecommendedModel` entries** (`RecommendedModelRegistry.swift`, sortOrder 26/27, `status: .experimental`)
   with **MEASURED** `estimatedMemoryGB`/`totalDiskSizeGB` (18.0/17.2 and 22.0/22.2) — not the param-count
   estimate, which is wrong for these A3B MoE models. `backend: .mlx` / `.gguf`; capabilities + context set.
2. **Sub-4-bit quant parsing** in `ModelFitService.parseEffectiveBits` — added IQ3/Q3 (3.4), IQ2/Q2 (2.4),
   IQ1/Q1 (2.1). Without this, `IQ2_XS` fell through to 4.5 bpw and the 80B was mis-estimated at ~45 GB
   (unfittable) instead of ~24 GB. Verified against 13 cases.

These touch only the catalog + fit estimator — **no backend/execution code changed**. Studio, calling the
existing facade, now sees both models, correctly fit-gated. The 80B is `.experimental` + flagged max-quality.

## Verification

- EshCore compiles clean with the changes. `parseEffectiveBits` logic verified standalone (13/13).
- Full `swift test` regression is currently blocked by an **environment** issue (the macOS Metal-toolchain
  cryptex is unmounted after reboot, so the `mlx-swift` dep can't compile its shaders) — unrelated to these
  edits, which live in EshCore and do not import mlx-swift. Re-run once the toolchain is restored
  (`xcodebuild -downloadComponent MetalToolchain`).

## Deliberately NOT done (optional follow-ups; need a decision, higher blast radius)

- **`license`/`commercialUse` on `RecommendedModel`:** absent today (license is only install-time provenance
  on `HuggingFaceInstallProvenance.licenseIdentifier`). Add a catalog field only if Studio must surface
  commercial-use at browse time. Qwen3 models are Apache-2.0 (commercial-OK), so not blocking.
- **Wire `ModelFitService` into `EshRuntime.planAuto`** (`EshRuntime.swift:540`, which today gates only on
  `capabilityReport(...).ready`, not fit). Needed only if Studio relies on auto-selection to *refuse* an
  over-ceiling model; otherwise the gate already lives at the catalog/recommend/install-preflight layer.
- **Runtime hard safety cap** reflecting the MEASURED swap-state ceiling (resident ≤ ~22 GB only with fresh
  headroom): inject `usableBudgetGB` into `RuntimeLifecycleManager` and/or tune `safeBudgetGB` reserve. The
  static `safeBudgetGB` (25.6 GB on 32 GB) does not know live swap state; a live-pressure gate before load of
  a ≥20 GB model is the robust follow-up (ties into `RuntimePressure`/`HostResourceProbe`).

## Studio guidance

Studio pins a model via `EshConstraints.pinnedModelID = "qwen-3-30b-a3b-mlx-4bit"` (default) or
`"qwen-3-next-80b-a3b-iq2xs-gguf"` (max-quality), or uses `--best`-style recommendation which now ranks these.
The GGUF 80B needs a llama.cpp with Qwen3-Next support (Homebrew b8660+ verified). As with all
non-sandboxed Python/GGUF engines, a sandboxed Studio must drop the App Sandbox or use the in-process
`LlamaCppEmbeddedBackend` path.
