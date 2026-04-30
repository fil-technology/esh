# Esh Orchestrator Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the macOS local model orchestrator surface described in `/tmp/esh-orchestrator-runtime/docs/esh-orchestrator-roadmap.md`.

**Architecture:** Add a small configuration layer, passive engine detection, and local model validation above the existing MLX and llama.cpp backends. Keep inference delegated to existing runtimes and keep GGUF/MLX routing at the backend registry layer.

**Tech Stack:** SwiftPM, Swift Testing, Foundation file/process APIs, existing EshCore persistence and backend services.

---

### Task 1: Config Surface

**Files:**
- Create: `Sources/EshCore/Domain/EshConfig.swift`
- Create: `Sources/EshCore/Services/EshConfigStore.swift`
- Create: `Sources/esh/Commands/ConfigCommand.swift`
- Modify: `Sources/esh/main.swift`
- Test: `Tests/EshCoreTests/OrchestratorConfigTests.swift`

- [ ] Write failing tests for default TOML, parse round-trip, `config init`, `config show`, and `config path`.
- [ ] Implement `EshConfig` with conservative TOML parsing/writing for the roadmap keys only.
- [ ] Implement `EshConfigStore` rooted at `PersistenceRoot.rootURL/config.toml`.
- [ ] Add `ConfigCommand` and route `esh config init|show|path`.
- [ ] Run targeted config tests.

### Task 2: Engine Detection Surface

**Files:**
- Create: `Sources/EshCore/Domain/EngineStatus.swift`
- Create: `Sources/EshCore/Services/EngineOrchestratorService.swift`
- Create: `Sources/esh/Commands/EnginesCommand.swift`
- Modify: `Sources/esh/Commands/DoctorCommand.swift`
- Modify: `Sources/EshCore/Backends/GGUF/LlamaCppBackend.swift`
- Test: `Tests/EshCoreTests/EngineOrchestratorTests.swift`
- Test: `Tests/EshUITests/OrchestratorCommandTests.swift`

- [ ] Write failing tests for passive `llama-cli` detection, disabled optional engines, MLX doctor failure reporting, and no Homebrew install attempt from `LlamaCppBackend`.
- [ ] Implement required engine statuses for `llama.cpp` and `mlx`.
- [ ] Implement optional detection/config status for `llamafile`, `ollama`, `transformers`, and `llama.cpp_server`.
- [ ] Update `esh doctor` and add `esh engines list|doctor`.
- [ ] Remove automatic `brew install llama.cpp` fallback from runtime resolution.
- [ ] Run targeted engine tests.

### Task 3: Local Model Validation

**Files:**
- Create: `Sources/EshCore/Domain/ModelValidation.swift`
- Create: `Sources/EshCore/Services/LocalModelValidationService.swift`
- Create: `Sources/esh/Commands/ValidateCommand.swift`
- Modify: `Sources/esh/main.swift`
- Test: `Tests/EshCoreTests/LocalModelValidationTests.swift`
- Test: `Tests/EshUITests/OrchestratorCommandTests.swift`

- [ ] Write failing tests for GGUF file validation, MLX directory validation, engine filtering, JSON output, and missing dependency suggestions.
- [ ] Implement local path and installed-model resolution.
- [ ] Detect GGUF files and MLX directories without loading model weights.
- [ ] Report compatible engines, ready engine selection, warnings, and suggested fixes.
- [ ] Wire `esh validate <model> [--engine llama.cpp|mlx] [--json]`.
- [ ] Run targeted validation tests.

### Task 4: Docs, Verification, Publish

**Files:**
- Modify: `README.md`
- Modify: `docs/USAGE.md`
- Modify: `CHANGELOG.md`
- Modify: `VERSION` only during release.

- [ ] Document the orchestrator commands and passive engine behavior.
- [ ] Run `swift test`.
- [ ] Run CLI smoke checks for `config`, `engines`, `doctor`, and `validate`.
- [ ] Run package smoke/release checks.
- [ ] Stage only in-scope files, commit, push branch, and create a release tag/artifact when verification passes.
