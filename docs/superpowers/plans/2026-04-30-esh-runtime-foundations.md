# Esh Runtime Foundations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add small orchestration-focused foundations for backend capability detection and normalized prompt cache identities.

**Architecture:** Keep esh as a local runtime orchestrator. Add additive domain types and protocol defaults so MLX and llama.cpp can report readiness and supported execution features without loading model weights. Add deterministic prompt cache keys to cache manifests while preserving compatibility with older manifests.

**Tech Stack:** SwiftPM, Swift Testing, Foundation, existing EshCore backend/cache services.

---

### Task 1: Backend Capability Reports

**Files:**
- Create: `Sources/EshCore/Domain/BackendCapabilities.swift`
- Modify: `Sources/EshCore/Protocols/InferenceBackend.swift`
- Modify: `Sources/EshCore/Backends/MLX/MLXBackend.swift`
- Modify: `Sources/EshCore/Backends/GGUF/LlamaCppBackend.swift`
- Test: `Tests/EshCoreTests/BackendCapabilityTests.swift`

- [x] Write failing tests for MLX and llama.cpp feature reporting.
- [x] Add stable feature enums and a capability report type.
- [x] Add a default protocol method so existing test backends remain source-compatible.
- [x] Implement MLX capability reporting for direct inference, token streaming, and prompt cache build/load.
- [x] Implement llama.cpp capability reporting for direct inference and token streaming, with cache features marked unavailable.
- [x] Run targeted capability tests.

### Task 2: Prompt Cache Normalization

**Files:**
- Create: `Sources/EshCore/Domain/PromptCacheKey.swift`
- Modify: `Sources/EshCore/Services/PromptSessionNormalizer.swift`
- Modify: `Sources/EshCore/Domain/CacheManifest.swift`
- Modify: `Sources/EshCore/Services/CacheService.swift`
- Test: `Tests/EshCoreTests/PromptSessionNormalizerTests.swift`
- Test: `Tests/EshCoreTests/CacheManifestTests.swift`

- [x] Write failing tests for deterministic, model-aware, backend-aware, tool-aware prompt cache keys.
- [x] Add a canonical prompt cache key payload and SHA-256 hashing.
- [x] Include the key on new cache manifests as an optional field for backward compatibility.
- [x] Run targeted prompt/cache tests.

### Task 3: Documentation And Verification

**Files:**
- Modify: `docs/PLANNING.md`
- Modify: `docs/USAGE.md`
- Modify: `README.md`

- [x] Document backend capability reports and normalized prompt cache keys.
- [x] Run `swift test`.
- [x] Commit as `feat: add runtime capability and prompt cache foundations`.
