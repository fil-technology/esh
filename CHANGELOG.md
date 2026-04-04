# Changelog

All notable changes to Esh should be documented in this file.

The format is based on Keep a Changelog, and Esh follows Semantic Versioning.

## [Unreleased]

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
