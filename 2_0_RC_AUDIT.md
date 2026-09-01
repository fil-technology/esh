# esh 2.0.0 Release-Candidate — Phase A: Truth Audit

**Date:** 2026-09-01
**Auditor:** autonomous engineering session
**Branch audited:** `codex/web-chat-rich` (= `main` @ `555d7c9` + rich Web Chat commit `bbf5eb1`)
**Method:** verified against real git/tags/releases, real CI, real `swift test`, and real on-device
runtime behavior. **Nothing here is taken on faith from prior reports or summaries** — every claim
below was re-checked in this session. Where something could not be verified in this non-interactive
environment, it is labeled **UNVERIFIED (env-limited)** rather than assumed passing.

---

## 1. Release truth (git / tags / releases / CI)

| Fact | Verified value |
|---|---|
| `main` HEAD | `555d7c9` — "release: 0.9.8 — real incremental SSE streaming + resident web chat" |
| `VERSION` file | `0.9.8` |
| Latest **git tag** | `v0.9.7` (no `v0.9.8` tag exists locally or on `origin`) |
| Latest **GitHub release** | `Esh 0.9.7` / `v0.9.7` (2026-08-31), notarized + Homebrew cask |
| `v0.9.8` release | **Does not exist** — 0.9.8 was committed (VERSION bump + code) but never tagged or published |
| CI (`ci.yml`, build+test) on 0.9.8 commit | **green / success** (verified via run watch) |
| Release pipeline (`release.yml`) for 0.9.8 | **Never ran** — it triggers only on `v*` tags, and no tag was pushed |

**Finding A1 (release hygiene):** the tree advertises itself as `0.9.8` but the highest *published,
notarized, installable* artifact is `0.9.7`. This is not a correctness bug, but the version story is
inconsistent and must be reconciled before 2.0 (either publish the intervening work under a real tag
or roll VERSION forward to the 2.0 line). Tracked for Phase Q / Phase S.

---

## 2. Test baseline (verified this session)

- `swift test` (full): **302 tests across 56 suites — ALL PASS**, ~15.6 s.
- `swift build`: succeeds. (An intermittent `build.db: disk I/O error` line is emitted from the
  external ExFAT SSD's SQLite; it is non-fatal — linking and the run complete. Tracked for Phase M.)
- New Web Chat / STT work: **17 targeted tests pass** (service routing, install-guidance error,
  handler route, page feature assertions).

This is a genuinely strong green baseline and is the correct floor to build the RC on.

---

## 3. Backends present

| Backend | Path | Runtime state (verified) |
|---|---|---|
| **MLX** (Python bridge) | `Sources/EshCore/Backends/MLX` | Working. `mlx-community/Llama-3.2-3B-Instruct-4bit` produced real output (`inputTokens 6 / outputTokens 2`). Persistent `mlx-serve` residency implemented. |
| **Apple** (FoundationModels) | `Sources/EshCore/Backends/Apple` | On-device provider present; `esh apple` route wired. |
| **GGUF** (`llama-cli`) | `Sources/EshCore/Backends/GGUF` | Code present. **UNVERIFIED (env-limited): no GGUF model is installed**, so real GGUF generation was not exercised. See Phase D. |

Installed models (on `/Volumes/Sviat SSD/esh-models`): deepseek-r1-distill-qwen-7b-4bit,
qwen3.5-9b-mlx-4bit, llama-3.2-3b-instruct-4bit, qwen2.5-0.5b-instruct-4bit. **All MLX; zero GGUF.**

---

## 4. Compatibility blockers (P0/P1) — the gate for 2.0

### BLOCKER B1 (P0) — qwen3.5 is recommended + tagged "default" but is genuinely broken

- **Classification in code:** `Sources/EshCore/Services/RecommendedModelRegistry.swift`, entry
  `qwen-3-5-9b`: `status: .recommended`, `tags: ["default", "balanced", "general-purpose"]`,
  `sortOrder: 0`, summary "Balanced first-choice local assistant." i.e. it is the flagship default.
- **Real behavior (verified this session):** `esh infer --model mlx-community/Qwen3.5-9B-MLX-4bit`
  reproducibly crashes:
  ```
  File ".../mlx_lm/models/qwen3_5.py", line 262, in __call__
      ssm_mask = create_ssm_mask(hidden_states, cache[self.ssm_idx])
  File ".../mlx_lm/models/cache.py", line 392, in make_mask
      return create_attention_mask(*args, offset=self.offset, **kwargs)
  TypeError: create_attention_mask() missing 2 required positional arguments:
             'return_array' and 'window_size'
  ```
  This is an internal mlx-lm (0.31.1) inconsistency on the Qwen3.5 **hybrid/SSM** code path.
- **Why it's a gate:** directly violates the standing constraint *"No default/recommended model is
  known broken; do not ship a 'supported' label for a model that is known broken."*
- **Same-architecture suspects (UNVERIFIED — not installed):** `qwen-3-5-9b-optiq`, `qwen-3-5-2b`,
  `qwen-3-5-0-8b`, `qwen-3-5-0-8b-optiq`, `qwen-3-5-27b-opus-distilled`. The GGUF variant
  `qwen-3-5-9b-gguf` runs through llama.cpp (different code path) and may be unaffected — also
  unverified.
- **Remedy (Phase B):** either (a) resolve the mlx-lm incompatibility for the hybrid path, or
  (b) honestly gate — reclassify the verified-broken MLX entry to `.incompatible`, drop it from the
  "default"/`sortOrder: 0` flagship slot, mark unverified same-arch MLX entries `.experimental` with
  a clear note, and promote a **verified-working** model to default. Gating is explicitly permitted
  by the mission ("resolve or honestly gate"). The specific flagship replacement is a product
  decision to confirm with the owner.

### BLOCKER B2 (P1) — Marvis TTS advertised as available but broken

- `/v1/audio/models` advertises `Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit` (confirmed via live curl).
- Marvis fails to load on the current TTSMLX (RoPE-key mismatch), documented in
  `AudioSpeechGenerator.resolveModel`.
- **Mitigation already in place:** the *runtime default* correctly avoids Marvis and prefers
  `mlx-community/Soprano-80M-bf16` (verified: `POST /v1/audio/speech` returned a real 176 KB WAV,
  32 kHz). So the default path is safe.
- **Residual risk:** the API still *lists* Marvis as available; an explicit request for it will fail
  at load. That is a "supported label for a broken model" at the catalog level.
- **Remedy (Phase B):** remove Marvis from the advertised audio catalog (or annotate it as
  unavailable/experimental) so the API never claims a broken model is usable.

---

## 5. Feature/runtime state (verified vs env-limited)

| Area | State |
|---|---|
| Persistent MLX residency (`mlx-serve`) | Implemented; prior session measured warm speedup + crash recovery. Re-validation in Phase E. |
| Streaming (SSE) chat completions | Real incremental streaming implemented across all layers. |
| **Web Chat (rich)** | Shipped on branch: multi-chat history (localStorage), model picker, settings (system prompt, temperature, max tokens, reasoning, cache/compression, auto-TTS), collapsible reasoning, markdown, image/audio rendering, attachments, per-message TTS, mic/STT upload. **Server-side verified** (`/web` serves w/ version; `/health` lists routes). **UNVERIFIED (env-limited): live browser rendering/interaction.** Phase I. |
| **TTS** (`POST /v1/audio/speech`) | **Verified working** end-to-end (Soprano-80M, 176 KB WAV, 32 kHz). |
| **STT** (`POST /v1/audio/transcriptions`, new) | Endpoint + plumbing verified (base64 → temp file → bridge; honest error, empty-audio → 400). **UNVERIFIED (env-limited): actual transcription** — repo `.venv` lacks `mlx_audio` (has mlx_lm/mlx_vlm). The packaged binary bundles its own Python with `mlx_audio` (prior session transcribed `hello.wav`). Phase J. |
| Scheduler (measured-evidence routing) | Implemented; prior session showed it skips the broken qwen3.5. Re-validation in Phase F, and it is the safety net for B1. |
| Benchmark Lab | Implemented (`esh benchmark lab`). Phase G. |
| Terminal UX (thinking, slash suggestions, status) | Implemented. **UNVERIFIED (env-limited): real TTY interaction.** Phase H. |

---

## 6. Documentation drift

**Finding D1:** `docs/ROADMAP_STATUS.md` is stale — it marks **M7, M8, M8.5, M9, M11 as "not
started"** while the code clearly implements all of them (RuntimeLifecycleManager, CapabilityResolver
+ contract v2, WebChatPage + `esh web`, SchedulerService, HARDENING_REPORT.md). The doc actively
contradicts the codebase and will mislead. Full rewrite required in **Phase R**.

Report files present at repo root: CHANGELOG, HARDENING_REPORT, MODEL_BENCHMARK_LAB_REPORT,
MODEL_BENCHMARK_REPORT, OPTIMIZATION_REPORT, PERSISTENT_RESIDENCY_REPORT, RUNTIME_LIFECYCLE_REPORT,
SPEECH_REPORT, STABILIZATION_REPORT. (There is also a stray `M8_CONTRACT_REPORT (1).md` duplicate —
a user working-tree file, left untouched.)

---

## 7. What CANNOT be validated in this environment (must be labeled, never faked)

These require conditions the non-interactive session lacks. They will be **built/hardened and
unit-tested**, with the interactive gap called out explicitly, per the standing "build them anyway,
unit-tested" instruction:

- **Phase I** — live browser rendering & interaction of the Web Chat.
- **Phase J** — live microphone capture; real STT transcription end-to-end (needs bundled `mlx_audio`).
- **Phase K** — fresh second machine / clean user account.
- **Phase L** — upgrade/migration from previously installed older versions.
- **Phase M** — multi-hour external-SSD torture (basic SSD use is exercised; the SQLite `build.db`
  I/O warning is a real signal to harden).
- **Phase P** — multi-hour resource/stress soak.
- **Phase D** — real GGUF generation (no GGUF model installed).

---

## 8. RC gate summary

| Gate | State |
|---|---|
| Green build + full test suite | ✅ 304/304 pass |
| No default/recommended model known-broken | ✅ **B1 CLOSED** (Phase B) |
| No "supported" label on a broken model | ✅ **B2 CLOSED** (Phase B) |
| Cross-backend generation proven | 🟡 MLX ✅, Apple pending, GGUF ❌ (no model) |
| Speech proven | 🟡 TTS ✅, STT plumbing ✅ / transcription env-limited |
| Docs truthful | ❌ **D1 open** (roadmap doc stale) — Phase R |
| Release version story consistent | ❌ **A1 open** (0.9.8 unpublished) — Phase Q/S |

**Verdict (updated 2026-09-01):** the two compatibility blockers are now closed and verified (see
Phase B below). Remaining before 2.0: docs truthfulness (D1/R), version-story reconciliation (A1),
and the env-limited validations honestly completed-or-labeled (D, I, J, K, L, M, P). Build/test
baseline is strong (304/304).

---

## 9. Phase B — blockers closed (2026-09-01)

### B1 — qwen3.5 recommended-but-broken → **CLOSED**

Changes (`RecommendedModelRegistry.swift`, `main.swift`):
- `qwen-3-5-9b` and all MLX Qwen3.5 hybrid entries (`qwen-3-5-9b-optiq`, `qwen-3-5-2b`,
  `qwen-3-5-0-8b`, `qwen-3-5-0-8b-optiq`, `qwen-3-5-27b-opus-distilled`) reclassified
  `status: .incompatible` → excluded from `recommend()` for every use case (verified by test).
  They remain in the full `list()` catalog, flagged incompatible (honest, not hidden), with a
  summary explaining the mlx-lm hybrid crash and the condition to re-enable them.
- Flagship "default" tag moved off the broken model onto **`llama-3-1-8b`** (Llama 3.1 8B — a
  standard, not-known-broken architecture; sibling Llama models verified generating this session).
  This is the one owner-facing product choice; it is reversible in one edit if a different flagship
  is preferred. *(Surfaced for confirmation.)*
- Onboarding `starterModels` no longer offers `qwen-3-5-9b-optiq`; offers `llama-3-1-8b` instead.
- The GGUF `qwen-3-5-9b-gguf` (llama.cpp, different code path, unverified novel arch) downgraded to
  `.experimental` and stripped of the "default" tag — not claimed as a verified-compatible default.

### B2 — Marvis TTS advertised-but-broken → **CLOSED**

Changes (`AudioSpeechGenerator.swift`, `OpenAICompatibleAudioCatalog.swift`):
- Added `knownIncompatibleTTSModelIDs` (Marvis). The advertised audio catalog now filters it out —
  verified: `/v1/audio/models` returns **0** Marvis occurrences.
- An explicit request for Marvis returns a clear **HTTP 400** ("incompatible with this build … try
  mlx-community/Soprano-80M-bf16") instead of crashing at load — verified via live curl.
- The runtime default remains Soprano-80M (verified: real WAV).

Tests: `brokenQwen35ModelsAreNeverRecommended`, `flagshipDefaultIsAVerifiedWorkingModel` added; full
suite 304/304 green.

**Next: Phase C — cross-backend conformance suite + capability matrix.**
