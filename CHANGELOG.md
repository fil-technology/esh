# Changelog

All notable changes to Esh should be documented in this file.

The format is based on Keep a Changelog, and Esh follows Semantic Versioning.

## [Unreleased]

### Added
- OpenAI-compatible audio speech generation at `POST /v1/audio/speech`, including direct WAV responses for terminal-driven agents and the TUI-hosted local API.

## [0.1.32] - 2026-04-25

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
