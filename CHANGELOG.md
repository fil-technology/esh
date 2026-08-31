# Changelog

All notable changes to Esh should be documented in this file.

The format is based on Keep a Changelog, and Esh follows Semantic Versioning.

## [Unreleased]

## [0.9.1] - 2026-08-31

### Added
- **M8 contract — remaining gaps closed.** Realized prompt-cache state as a first-class, honest
  execution signal (`cacheHit` + `cachedTokens` reused on `Metrics`/`EshUsage.cachedInputTokens`/
  `ExecutionProfile.cacheHit`, distinct from the chosen strategy). Typed `EshAttachment`
  (image/document/audio) on requests, resolved honestly as rejected — never silently dropped — with a
  reason distinguishing a model-capability gap from an esh-execution gap. **Apple Foundation Models
  participate in the capability contract** (`esh capabilities` → `appleProvider`): honest
  availability, on-device-only by construction (`permitsCloudOrPCC=false`, `neverAutoSelected=true`),
  limitations listed not hidden. A consolidated cross-backend M8 conformance suite. See
  M8_CONTRACT_REPORT.md (M8 honesty contract now substantially complete; making Apple a
  routable/schedulable backend is deferred as a design decision).

## [0.9.0] - 2026-08-31

### Added
- **Persistent, weights-resident MLX runtime (true residency).** A new `mlx-serve` worker loads a
  model ONCE and serves many requests over a newline-delimited JSON protocol, so MLX "warm" can mean
  weights actually stay in memory instead of reloading per request. Owned by the existing
  `RuntimeLifecycleManager` (no parallel manager): streaming, cancellation, crash detection +
  automatic restart, graceful unload, idle/memory-pressure eviction, bounded concurrency, and clean
  shutdown — with no orphan workers (a worker exits when esh does). Truthful residency + health are
  surfaced through pool status and `ExecutionProfile.residency`. Opt-in via `ESH_MLX_PERSISTENT=1`
  until a stability soak justifies default-on. Benchmarked ~13× faster warm requests (0.24s vs 3.28s
  reload-per-request) on qwen2.5-0.5b; savings scale with model size. See PERSISTENT_RESIDENCY_REPORT.md.
- **Inference Contract v2 (M8) progress.** Canonical tools (`EshToolDefinition`/`EshToolChoice`/
  `EshToolCall`) and normalized usage (`EshUsage`) with **measured** input/output/total tokens from
  the MLX runtime (never fabricated; local monetary cost = 0 with provenance). **Native constrained
  decoding on GGUF (llama.cpp)** — strict `json_schema`/`grammar` resolve to `.applied` and are
  enforced via `--json-schema`/`--grammar`; MLX/ONNX honestly report `.approximated`/`.rejected`
  (no silent prompt-instruction substitution). Honest per-backend reasoning capability resolution.
  A canonical streaming event model (`EshStreamEvent`) with a real text-stream adapter. See
  M8_CONTRACT_REPORT.md (M8 is advancing, not yet complete).

## [0.8.1] - 2026-08-31

### Fixed
- **Critical: packaged-binary runtime discovery when invoked as a bare command.** Bundled-runtime
  resolution (MLX `mlx_vlm_bridge.py`, `llama-cli`, TurboQuant helper, TTS metallib) and `VERSION`
  lookup were keyed off `CommandLine.arguments[0]`. Under a PATH/shim invocation — the normal
  `esh …` Homebrew case — `argv[0]` is often the bare command name and resolves against the current
  working directory, so the packaged root came back `nil`: `ESH_MLX_VLM_BRIDGE` was never set and
  MLX inference failed pointing at a build-machine path (`/Users/runner/work/esh/…`), while
  `esh version` reported `unknown`. All executable-relative lookups now resolve the true image path
  via `_NSGetExecutablePath`. Verified end-to-end: bare `esh` from an unrelated directory now
  resolves the version and runs MLX inference (0.8.0 fails the same invocation).
- Homebrew cask: use the non-deprecated `depends_on macos: :ventura` symbol form.

## [0.8.0] - 2026-08-31

### Added
- **Runtime Lifecycle / Warm Pool (M7).** A backend-agnostic `RuntimeLifecycleManager` above MLX/llama.cpp/Apple: loaded-model registry with per-model state (unloaded/loading/warm/active/idle/unloading/failed), concurrent-load dedup, a unified-memory budget with configurable safety + TTS reserves (text+speech coexistence), idle-timeout and memory-pressure eviction (LRU) with over-budget refusal, bounded concurrency with interactive-over-background priority, cancellation, and prewarming. `esh serve` runs with a shared pool; the Adaptive Scheduler is resource-aware (an already-warm model wins close calls, recorded in the rationale). **Truthful residency:** the pool tracks/reports `RuntimeResidency` (`weights-resident` vs `handle-cached`). Real-runtime measurement confirmed today's MLX (subprocess-per-generate) is **handle-cached, not truly weight-resident** — `warm` means a handle is available, and callers must read `residency` for true warmth. Memory distinguishes estimated vs measured. See RUNTIME_LIFECYCLE_REPORT.md. Follow-up: a persistent MLX bridge for real weight residency.

## [0.7.0] - 2026-08-31

### Added
- **Model Benchmark Lab v1 (recommendation engine).** `esh model recommended --explain [--profile] [--json]` produces fit-aware, per-profile recommendations for this Mac (general/coding/reasoning/fast/low-memory/long-context/tools/best-quality) over a versioned dataset schema. Rankings exclude models that don't fit, prefer comfortable/fits, and are honestly labeled `estimated` unless you've locally benchmarked the model — in which case your measured decode speed supersedes/annotates the ranking (`measured-local`). No fabricated quality numbers. Candidate discovery is researched live. See MODEL_BENCHMARK_REPORT.md.
- **Execution transparency.** Inference responses now include an `executionProfile` reflecting the KV/prompt-cache strategy that actually ran, for the Scheduler / Web Chat / Terminal UX.
- `docs/GAP_AUDIT.md`: honest audit documenting which milestones are complete vs. slices (M7/M8/structured-gen/cache/update/apple).

## [0.6.0] - 2026-08-31

### Added
- **Adaptive Intelligence Scheduler v1 (M9).** `esh schedule` takes a capability request under constraints — `--goal general|coding|reasoning|structured --quality high|balanced|fast --latency interactive|batch --context N --tools --vision` — and picks the best installed model + optimization plan for this Mac, recording the rationale (`--json` for tooling). It composes catalog capabilities, per-model fit, and the M1 optimizer's benchmark evidence: it filters by required capabilities, excludes models that don't fit, ranks by fit then quality-aligned size, and derives the performance mode (dropping to `memory` for tight fits). When no installed model satisfies the request it *suggests* Apple Intelligence (only for modest, tool-free requests) or installing a model — a suggestion, never a silent substitution. (Live memory-pressure/warm-pool state is an M7 input, taken as a parameter for now and noted honestly.)

## [0.5.0] - 2026-08-31

### Added
- **Structured output + honest capability resolution (Inference Contract v2, first slice).** The native infer contract gains `response_format` (text / json / json_schema / grammar). `esh infer --response-format json [--json-schema <path-or-text>]` and the JSON response now include a `capabilityResolution` block reporting exactly how each requested option was handled — `applied` / `transformed` / `ignored` / `rejected` — so esh never silently pretends an unsupported option was honored. json/json_schema are approximated via an injected instruction (clearly labeled "not guaranteed" since MLX has no native constrained decoding); grammar is `rejected`. Backward-compatible: pre-existing infer request JSON still decodes.

## [0.4.0] - 2026-08-31

### Added
- **Apple Intelligence generation.** `esh apple <prompt> [--system …]` runs the on-device Apple Foundation Models system model with zero model downloads; `esh apple status [--json]` reports availability. Guarded so it compiles/runs without the FoundationModels SDK, throws clearly when unavailable, and is never used to replace an explicitly requested MLX/GGUF model. (Full provider integration into the capability contract is planned for a later milestone.)
- **`esh update check [--json]`.** Explicit update-check surface with a documented notify-only policy — esh reports a newer release (`brew upgrade --cask esh`) but never installs an executable update itself (`autoInstall: false`).
- `docs/ROADMAP_STATUS.md` tracking milestone status against the delivery roadmap.

## [0.3.0] - 2026-08-31

### Added
- **Optimization Foundation (M1).** A pluggable optimization boundary: strategies (KV-cache incl. TurboQuant, prompt cache) are data behind `OptimizationStrategy`; the `OptimizationPlanner` produces a serializable `ExecutionProfile`. A benchmark harness runs strategies through the **real** inference path and persists raw results keyed by hardware/model/backend/runtime; `auto` selects a non-baseline strategy only with local measured evidence that clears a quality floor (applied in every mode). New `esh performance <auto|speed|balanced|memory>` and `esh optimize status|strategies|plan|benchmark|compare|reset` (all `--json`). See OPTIMIZATION_REPORT.md and docs/OPTIMIZATION.md.
- **Pre-download model-fit gate.** Before downloading multi-GB weights, esh estimates fit against chip/unified-memory/context/disk/storage and classifies it comfortable/fits/tight/unlikely/unsupported/unknown with a memory breakdown and rationale. Soft gates (tight/unlikely/unknown, insufficient disk) require confirmation or `--force`; only genuine technical incompatibility or an unavailable storage volume is blocked. esh never substitutes a different model. New `esh model fit <model>`.
- **Apple Foundation Models detection.** `esh doctor` and `esh onboard` report Apple Intelligence (Apple Foundation Models) availability as a zero-download on-device provider (available / deviceNotEligible / appleIntelligenceNotEnabled / modelNotReady / unsupported), distinct from Private Cloud Compute. Full inference integration is planned for the Capability API / Scheduler milestones.

### Changed
- `ModelInstallPreflightService` no longer hard-blocks installs on predicted memory/disk pressure — memory is a soft fit gate so knowledgeable users can still try a model; only unsupported format/architecture blocks.

## [0.2.0] - 2026-08-31

### Added
- **External-SSD storage.** Large AI assets (model weights, GGUF files, TTS voices, caches, downloads) can live on an external volume while lightweight config/state stays on the internal disk. `esh storage show|set|use-internal|doctor|migrate` (human + `--json`). A volume-marker scheme detects a disconnected drive and fails with a clear "Model storage volume is unavailable" error instead of silently re-downloading huge assets to the internal disk. `ESH_ASSETS_HOME` overrides the assets root.
- **Guided onboarding.** `esh onboard` detects the Mac (chip/RAM/macOS/engines), chooses storage, recommends a hardware-matched model, installs it, and finishes with next steps. Safe to re-run; `--status` (non-interactive summary) and `--yes` (auto-install) modes. Persisted, versioned onboarding state.
- **Hardware-aware model catalog.** Recommended models now carry context window, structured capabilities (chat/coding/reasoning/tool-calling/vision), and status (recommended/experimental/legacy/incompatible). `esh model recommended --for-this-mac` and `--profile coding|reasoning|fast|best|low-memory`; new `esh model info <model>` and `esh model compatibility <model>`.
- **First-class local models.** `esh model import <path>` registers a local MLX directory or GGUF file with no re-download (copy or `--move`); `esh model scan [<dir>] [--clean]` discovers models already on storage and cleans orphaned partial downloads.
- **Richer diagnostics.** `esh doctor --json` emits a stable machine-readable health report (status, host, storage, engines, models); human output now includes storage availability, host, and incomplete-install detection.

### Changed
- Aligned swift-syntax with the Swift 6.3 toolchain (600.0.1 → 603.0.2).
- TTS voice models and generated audio now write under the configured assets root (e.g. `~/.esh/audio`) instead of the current working directory.
- Config gains an explicit schema version; the unused `model_dir` knob is deprecated in favor of `esh storage`. Path expansion (`~`, `$HOME`, relative, absolute) is standardized.
- `esh doctor` remains a non-failing diagnostic: it reports `degraded` (e.g. when only one engine is available) but exits 0; pass `--strict` to make a non-`ok` status exit non-zero for health-gating.

## [0.1.41] - 2026-05-12

### Fixed
- Packaged MLX and TurboQuant runtimes now resolve their bundled Python helper paths from the installed release layout instead of falling back to compile-time source checkout paths.

## [0.1.40] - 2026-05-07

### Added
- Added MLX 0.5 generation controls for thinking-mode chat templates and KV-cache quantization across OpenAI-compatible requests, external inference, the CLI, and the MLX bridge.
- Advertised MLX thinking-mode and KV-cache quantization capabilities while explicitly marking `json_schema` response format constrained decoding as unavailable.

## [0.1.39] - 2026-05-07

### Changed
- Updated the MLX VLM bridge dependency contract to `mlx-vlm` 0.5.0 with compatible `mlx` and `mlx-lm` minimum versions.
- Bumped MLX cache/runtime metadata to `mlx-vlm-0.5.0+mlx-lm-bridge-v3` so older 0.4.3 prompt-cache artifacts remain version-isolated.

## [0.1.38] - 2026-04-30

### Added
- Backend capability reports for MLX and llama.cpp runtime feature detection.
- Normalized prompt cache keys on new cache manifests for future cache lookup and reuse policy.

## [0.1.37] - 2026-04-30

### Added
- Runtime orchestration commands: `esh config`, `esh engines list`, `esh engines doctor`, and `esh validate`.
- Passive llama.cpp and MLX readiness checks with local model validation for GGUF files and MLX model directories.
- Optional engine tracking for llamafile, Ollama, Transformers, and llama.cpp server adapters.

### Changed
- llama.cpp runtime lookup no longer attempts automatic Homebrew installation; it now reports the missing dependency and suggested fix.

## [0.1.35] - 2026-04-29

### Added
- Runtime generation controls for chat, `esh infer`, OpenAI-compatible requests, Anthropic-compatible requests, MLX, and GGUF backends.
- Chat commands for inspecting and changing generation options while a session is running.

### Fixed
- OpenAI and Anthropic local compatibility now tolerates non-text content parts instead of rejecting requests that include image or unsupported parts.
- Packaged smoke tests now skip MLX doctor failures only when the current macOS session cannot expose a Metal GPU.

## [0.1.33] - 2026-04-25

### Added
- OpenAI-compatible audio speech generation at `POST /v1/audio/speech`, including direct WAV responses for terminal-driven agents and the TUI-hosted local API.

### Fixed
- Debug SwiftPM builds no longer emit stale clang module-cache warnings.

## [0.1.31] - 2026-04-25

### Fixed
- Xcode local model provider compatibility by keeping `/v1/models` text-only and adding local-provider probes.

### Added
- OpenAI-compatible server now exposes `/v1/tools`, `/api/tags`, root health, query-safe routing, CORS headers, and port `11435` defaults for Xcode.

## [0.1.30] - 2026-04-25

### Fixed
- SwiftPM build no longer reports unhandled `mlx-audio-swift` README files.

## [0.1.29] - 2026-04-25

### Added
- TUI launcher now exposes an OpenAI server toggle with live on/off state.
- Chat TUI now shows OpenAI server state in the header and supports `/serve toggle|start|stop|status`.

## [0.1.28] - 2026-04-25

### Added
- `esh serve` exposes an OpenAI-compatible local HTTP server for model listing, chat completions, and responses.
- OpenAI-compatible model discovery now includes MLX TTS audio models plus `/v1/audio/models` voice/language metadata for external agents.

## [0.1.27] - 2026-04-24

### Fixed
- MLX chat cache export now handles bfloat16 prompt-cache tensors without failing generation.

## [0.1.26] - 2026-04-24

### Fixed
- macOS release packages now include the MLX Metal runtime library required by `esh audio speak`
- package smoke tests now fail when the bundled MLX Metal runtime library is missing

## [0.1.25] - 2026-04-24

### Added
- `esh audio` commands for listing MLX TTS models and generating WAV speech through TTSMLX
- an interactive Audio launcher entry for choosing a TTS model, voice, language, profile, and output path
- model task, modality, and capability metadata, including `esh model list --task` and `--capability` filters

### Changed
- model install preflight can proceed past unsupported runtime verdicts when `--force` is used
- generated `.esh` model and audio cache data is ignored by Git

## [0.1.24] - 2026-04-24

### Added
- expanded recommended model presets with additional Qwen, DeepSeek, Phi, Gemma, and GGUF options
- catalog coverage for the new recommended model aliases and backend-specific ordering

## [0.1.23] - 2026-04-24

### Added
- optional multi-model routing configuration with router, main, coding, embedding, and fallback model roles
- `esh routing` commands for status, enable/disable, role assignment, mode selection, and local routing tests
- routed `esh infer` and `esh chat --routing` execution with deterministic router JSON validation
- safe workspace-bounded `read_file` tool handling for routed filesystem requests

### Changed
- routed inference falls back to the main model when the router is unavailable, emits invalid JSON, has low confidence, or proposes an invalid tool call
- `parallel` routing mode is accepted as configuration and currently runs through the sequential fallback path

## [0.1.22] - 2026-04-11

### Added
- bounded autonomous agent mode can now create files, edit line ranges, and run explicit build/test verification steps
- agent runs now support resumption with `esh agent continue --run <id> --model <id-or-repo>` using compact continuation memory from persisted run state
- terminal chat now supports transcript scrolling for long responses with line, page, and jump navigation

### Changed
- agent final answers are now gated on successful verification after code edits, with repair-and-retry behavior after failed verification
- run state now records agent task lifecycle and per-step trace events for clearer status inspection and continuation

## [0.1.21] - 2026-04-04

### Changed
- no-model onboarding now supports switching between MLX and GGUF starter presets
- no-model onboarding and recommended presets now offer direct full-catalog search from the picker
- launcher search copy now reflects MLX and GGUF model discovery instead of MLX-only wording

## [0.1.20] - 2026-04-04

### Added
- arrow-key model disambiguation pickers for install, open, and check flows after search returns multiple matches

### Changed
- the shared model chooser now makes `Esc` cancellation explicit alongside `Enter` selection

## [0.1.19] - 2026-04-04

### Added
- backend switching between MLX and GGUF in the recommended-models picker
- a terminal-native interactive text prompt for launcher queries so search/install prompts no longer depend on `readLine()` after raw-key menus

### Changed
- model search results now install on `Enter` and open on `o`
- opening a model page from search, recommended presets, starter presets, chat model selection, or installed models now keeps you in the current picker instead of dropping you back to the launcher

## [0.1.18] - 2026-04-04

### Added
- `esh model check` with pre-download compatibility and fit estimates, JSON output, and conservative host-memory heuristics
- initial GGUF support through llama.cpp, including backend routing, support checks, and explicit `--variant` handling for GGUF quant variants
- GGUF-aware metadata inference and tests for format detection, quantization mapping, variant selection, and stable checker output

### Changed
- Hugging Face remote search now surfaces broader supported model results instead of forcing the old MLX-only app filter
- model install can now prompt for GGUF variants when a repo exposes multiple candidate files
- launcher and startup banner UI now size correctly for live counts and search/install flows remain usable from the interactive menu

## [0.1.5] - 2026-04-03

### Added
- colorful startup banner with live model/session/cache counts in the launcher
- model capability badges such as `chat`, `code`, `reason`, `vision`, and `long` in model pickers
- reasoning-aware chat formatting for models that emit explicit `<think>...</think>` blocks

### Changed
- launcher and model lists now use interactive highlighted pickers with arrow-key navigation
- pressing Enter on `Chat` now opens chat immediately, while `n` opens the named-session flow
- launcher descriptions now render inline on the right for a tighter command-palette layout

## [0.1.4] - 2026-04-03

### Added
- `esh model open` for opening a model page from an alias, installed id, repo id, or search term
- interactive highlighted pickers for the launcher menu and model selection flows

### Changed
- Hugging Face model search now uses the strict `apps=mlx-lm` filter
- model search and model lists now support opening and installing directly from the selected row
- launcher list descriptions now render inline on the right for a more compact layout

## [0.1.3] - 2026-04-03

### Added
- install-by-search now shows a numbered model chooser before any download starts
- install preflight now checks unified memory, available memory, and free disk space before downloading

### Changed
- stale partial downloads that trigger HTTP 416 now restart that file from zero automatically

## [0.1.2] - 2026-04-03

### Added
- `esh model recommended` with built-in stable MLX presets for fast first-time setup
- alias-based model install, for example `esh model install fast-chat`

### Changed
- model search output now uses compact fixed-width columns with source, state, model, kind, size, downloads, and date

## [0.1.1] - 2026-04-03

### Added
- `esh model search <query>` across local installs and Hugging Face
- a shared model catalog layer for local and remote discovery
- default launcher menu support for model search

## [0.1.0] - 2026-04-03

### Added
- local MLX-backed chat for Apple Silicon
- model install/list/inspect/remove
- saved sessions and in-chat session switching
- raw and TurboQuant cache build/load/inspect flow
- self-contained dev and release launchers
