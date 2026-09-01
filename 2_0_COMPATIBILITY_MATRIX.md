# esh 2.0.0 — Cross-Backend Capability & Compatibility Matrix (Phase C)

**Date:** 2026-09-01
**Source of truth:** `Sources/EshCore/Services/CapabilityResolver.swift`, `Domain/BackendKind.swift`,
and the conformance suite (`M8ConformanceTests`, `CapabilityResolverTests`, `BackendCapabilityTests`).
Every "applied/approximated/rejected/ignored" cell below is enforced by a passing test — the resolver
never silently pretends an unsupported option was honored.

**Legend**
- ✅ **applied** — honored natively/really.
- ➖ **approximated** — best-effort via prompt instruction; not guaranteed. Rejected instead when the
  caller sets `strict`.
- ⛔ **rejected** — explicitly refused with a reason (never silently ignored).
- 🚫 **ignored (honest)** — the backend has no such control; reported as ignored, not faked as applied.
- 🧪 **env-limited** — code path present but not exercised end-to-end in this non-interactive session
  (labeled, never claimed as verified).

---

## 1. Backends

| Backend | Transport | Runtime state |
|---|---|---|
| **MLX** | out-of-process Python bridge (`mlx-lm`/`mlx-vlm`), persistent `mlx-serve` residency | ✅ verified generating this session (Llama 3.2 3B, DeepSeek-R1 7B) |
| **GGUF** | `llama-cli` (llama.cpp) | 🧪 code present; **no GGUF model installed** → real generation not exercised here (see Phase D) |
| **Apple** | FoundationModels (on-device) | 🧪 provider wired; on-device availability depends on host; `esh apple` route present |
| **ONNX** | reserved backend kind | not a shipping generation path; included for honest resolver coverage |

---

## 2. Inference capability matrix

| Capability | MLX | GGUF | Apple | ONNX |
|---|---|---|---|---|
| Text response (`response_format: text`) | ✅ | ✅ | ✅ | ✅ |
| JSON (non-strict) | ➖ prompt | ✅ native (constrained) | ➖ prompt | ➖ prompt |
| JSON (**strict**) | ⛔ rejected | ✅ native | ⛔ rejected | ⛔ rejected |
| JSON Schema (non-strict) | ➖ prompt | ✅ native (schema→grammar) | ➖ prompt | ➖ prompt |
| JSON Schema (**strict**) | ⛔ rejected | ✅ native | ⛔ rejected | ⛔ rejected |
| Grammar (GBNF) | ⛔ rejected | ✅ native (when grammar given) | ⛔ rejected | ⛔ rejected |
| Reasoning / thinking toggle | ✅ `enable_thinking` → chat template | 🚫 ignored (template decides, inline) | 🚫 ignored (no toggle) | 🚫 ignored |
| Native tool / function calling | ⛔ rejected → use `esh agent` | ⛔ rejected → use `esh agent` | ⛔ rejected → use `esh agent` | ⛔ rejected |
| Attachments (images/audio) on inference path | ⛔ rejected (reason distinguishes model-vision vs esh-path gap) | ⛔ rejected | ⛔ rejected | ⛔ rejected |
| Streaming (SSE, incremental) | ✅ real per-token | 🧪 via same server path | 🧪 | 🧪 |
| Usage accounting (tokens) | ✅ measured; `reasoningTokens` only when truly reported | ✅ measured | ✅ | — |
| Monetary cost | ✅ **$0**, provenance = on-device/local (never fabricated) | ✅ $0 | ✅ $0 | — |

**Key honesty invariants (test-enforced):**
- `strictStructuredOutputIsNativeOnGGUFAndRejectedElsewhere` — strict structured output is native only
  on GGUF; every other backend **rejects** rather than approximating.
- `toolsAreRejectedHonestlyOnEveryBackend` — no backend claims native tool calling.
- `reasoningIsIgnoredOnGGUFNotFakedAsApplied` + `reasoningIsIgnoredHonestlyOnAppleAndOnnx` — only MLX
  reports reasoning as *applied*; others report *ignored*.
- `unsupportedStructuredBehaviorIsNeverSilent` — every unsupported structured request yields a
  non-silent resolution the caller can see.
- `localUsageHasZeroMonetaryCostWithProvenance` / `appleProviderParticipatesWithOnDeviceOnlyGuarantees`
  — local/Apple runs are $0 with on-device provenance; Apple is on-device only.

---

## 3. Model catalog compatibility (post Phase B gating)

| Model family | Backend | 2.0 status |
|---|---|---|
| Llama 3.x (3B/8B), Mistral Small 24B, Qwen 2.5 (+Coder), DeepSeek-R1 distill (Qwen), Phi, Gemma | MLX | ✅ recommended (standard architectures). Mistral Small 24B = **flagship default**. |
| **Qwen 3.5 (all MLX sizes: 9B/2B/0.8B, incl. OptiQ, 27B distilled)** | MLX | ⛔ **incompatible** — reproducible mlx-lm hybrid/SSM crash. Excluded from recommendations; listed-but-flagged in catalog. |
| Qwen 3.5 9B GGUF | GGUF | 🧪 **experimental** — novel arch unverified via llama.cpp; not a default. |
| GGUF catalog (Llama 3.2 3B, Qwen2.5 Coder, DeepSeek-R1 14B/7B, Phi) | GGUF | 🧪 recommended entries present; **real GGUF generation unverified** (no model installed). Phase D. |

---

## 4. Speech capability matrix

| Capability | State |
|---|---|
| TTS (`POST /v1/audio/speech`) | ✅ verified — Soprano-80M, real 176 KB WAV @ 32 kHz |
| TTS default selection | ✅ avoids broken Marvis; prefers Soprano-80M / pocket-tts |
| Marvis TTS | ⛔ filtered from catalog; explicit request → HTTP 400 (honest, no crash) |
| STT (`POST /v1/audio/transcriptions`) | ✅ endpoint + plumbing verified; 🧪 **real transcription env-limited** (dev `.venv` lacks `mlx_audio`; packaged binary bundles it) |

---

## 5. What Phase C did NOT change

The conformance suite already existed and is comprehensive; Phase C added Apple/ONNX reasoning
coverage and produced this matrix. No resolver behavior was altered — the matrix documents existing,
test-backed honesty. Cross-backend *runtime* proof for GGUF and Apple remains env-limited and is
tracked in Phases D and (for Apple availability) K.
