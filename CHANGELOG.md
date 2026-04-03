# Changelog

All notable changes to Esh should be documented in this file.

The format is based on Keep a Changelog, and Esh follows Semantic Versioning.

## [Unreleased]

### Added
- explicit `esh chat --model <id-or-repo>` model selection
- session/model name support across more CLI commands
- `esh benchmark` and `esh benchmark history`
- session search with `esh session grep <text>`
- in-chat `/use-model`, `/model current`, and `/search`
- GitHub Actions CI and release packaging

## [0.1.0] - 2026-04-03

### Added
- local MLX-backed chat for Apple Silicon
- model install/list/inspect/remove
- saved sessions and in-chat session switching
- raw and TurboQuant cache build/load/inspect flow
- self-contained dev and release launchers
