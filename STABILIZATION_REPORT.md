# esh 1.x Stabilization Report

Program: make esh (the local intelligence/runtime engine) exceptionally stable, easy to install,
easy to configure, and dependable before esh 2.0. Executed phase-by-phase against the real
repository. Companion documents: [docs/STABILIZATION_BASELINE.md](docs/STABILIZATION_BASELINE.md)
(Phase 0 truth audit) and [docs/STORAGE.md](docs/STORAGE.md).

Branch: `codex/esh-stabilization`. Baseline and final state both build clean; the test suite grew
from **130 → 171 tests** (all green), with **41 new tests** across storage, doctor, catalog,
onboarding, local import, and config migration.

---

## 1. Baseline discovered (Phase 0)

- `swift build` and `swift test` were **green** at baseline (130 tests). Swift 6.3.3 toolchain,
  `platforms: [.macOS(.v14)]`.
- **Storage was scattered.** `PersistenceRoot` knew only 4 of the ~12 real `~/.esh` subdirs; the
  rest were hard-coded per-service. The `model_dir` config knob was **dead** (never read). The only
  relocation mechanism was `ESH_HOME`, which moved *everything*.
- **⚠️ TTS voice weights and generated audio wrote to `<cwd>/.esh/…`**, not `~/.esh` — running from
  different directories duplicated multi-GB caches.
- **The 26-model catalog was real and current** (verified live on HuggingFace; several families —
  Qwen3.5, Gemma-4, OptiQ — postdate the engine's built-in model knowledge). The gap was *metadata*
  (no context window, capabilities, or status), not fabricated entries.
- Downloads were resumable but had no `.partial` staging/completion marker beyond the manifest, and
  no checksum (byte-count only). No local-model import or discovery.
- `doctor` was text-only (no JSON for Ashex) and didn't check storage/free-space/corruption/ports.
- **No onboarding** command existed. Config used a hand-rolled TOML parser with no schema version.
- Docs drifted (`esh model install fast-chat` referenced a non-existent alias).

Full detail with file:line references: [docs/STABILIZATION_BASELINE.md](docs/STABILIZATION_BASELINE.md).

---

## 2. Architecture changes made

| Area | Change |
|---|---|
| **Storage** | New `StorageLayout`/`StorageConfig`/`StorageMarker` + `StorageService`; `PersistenceRoot` split into a **state root** (internal) and an **assets root** (relocatable). |
| **Paths** | `PathResolving` centralizes `~`/`$HOME`/relative/absolute expansion (replaced 3 duplicated expanders). |
| **Diagnostics** | `DoctorService` produces a single Codable `DoctorReport` (reused by `esh doctor --json`). |
| **Catalog** | `RecommendedModel` enriched (context/capabilities/status); `RecommendedModelRegistry.recommend(useCase:host:)` for hardware-aware picks. |
| **Onboarding** | `OnboardingService` (testable core) + `OnboardCommand` (TUI + non-interactive). Versioned `OnboardingState`. |
| **Local models** | `LocalModelImportService`: import/discover/clean, first-class local models. |
| **Config** | `EshConfig` schema version + deprecation of `model_dir`. |

Design principle throughout: **evolutionary, additive, backward-compatible**. No working subsystem
was rewritten; existing call sites kept working (e.g. assets root defaults to the state root, so a
zero-config install behaves exactly as before).

---

## 3. Dependencies updated (Phase 1)

| Package | From | To | Why |
|---|---|---|---|
| swift-syntax | 600.0.1 | **603.0.2** | Majors track Swift releases; 603.x == Swift 6.3. `from:600.0.1` pinned it 3 majors behind. Used only by `SymbolExtractor.swift` via the stable `SyntaxVisitor` API; 603.0.2 ships a prebuilt for the exact 6.3.3 toolchain. |
| TTSMLX | 0.3.3 | **held** (0.7.0 available) | Large 0.3→0.7 jump; the TTS path can't be verified end-to-end without real Metal+synthesis in this environment. Flagged for a follow-up with manual TTS validation. |
| mlx-audio-swift | rev `c96fe7b8` | **held** | Revision pin kept for TTSMLX 0.3.3 compatibility (documented reason). |
| mlx-swift / mlx-swift-lm | 0.31.3 / 2.31.3 | **held** | Transitive via mlx-swift-lm; leave to its constraint until an MLX bridge change needs it. |

Python helpers (`Tools/python-requirements.txt`) unchanged: `mlx>=0.31.2`, `mlx-lm>=0.31.3`,
`mlx-vlm==0.5.0`.

---

## 4. Storage layout / schema (Phase 2)

Two roots (full detail in [docs/STORAGE.md](docs/STORAGE.md)):

- **State root** (`~/.esh` or `$ESH_HOME`, always internal): `config.toml`, `storage.json`,
  `onboarding.json`, `sessions/`, `benchmarks/`, `runtime/` (Python venv), metadata.
- **Assets root** (default = state root; relocatable via `esh storage set` or `$ESH_ASSETS_HOME`):
  `models/`, `caches/`, `audio/` (incl. `tts-models/`), `tmp/`.

`storage.json` (internal, so readable when the volume is gone):
```json
{ "schemaVersion": 1, "assetsRoot": "/Volumes/AI/esh", "assetsVolumeID": "<uuid>" }
```
A marker file `<assetsRoot>/.esh-storage.json` carrying the same id proves the expected volume is
mounted. Availability = directory present **and** marker present **and** id matches **and**
writable. Large writes (model install, TTS download) are gated on this → clear
`StorageError.volumeUnavailable`, never a silent internal fallback. Verified live with a
disconnect→reconnect cycle and a path containing a space.

---

## 5. Migration behavior (Phases 2, 7)

- **Zero-config**: existing `~/.esh` installs are unchanged (assets root = state root).
- **Legacy `~/.llmcache` → `~/.esh`**: existing PersistenceRoot migration preserved and now tested.
- **Assets relocation**: `esh storage set <path>` moves `models/caches/audio/tmp` (merge-aware,
  copy+remove across volumes); `esh storage use-internal` moves them back.
- **Config**: files without `[meta] schema_version` default to v1 (custom Decodable + TOML parser);
  `model_dir` still parsed but deprecated in favor of `esh storage`.
- **Local model discovery**: `esh model scan` registers models already present under the store
  (e.g. on a reconnected SSD) without re-download.

---

## 6. Curated recommended models (Phase 3)

26 entries (19 MLX + 7 GGUF), **all verified live on HuggingFace** with correct on-disk format
(`ESH_LIVE_HF_TESTS=1` integration test). Each carries a real context window (fetched from
`config.json`), structured capabilities, and a status. Highlights:

| Alias | Repo | Ctx | Caps | Status |
|---|---|---|---|---|
| qwen-3-5-9b | mlx-community/Qwen3.5-9B-MLX-4bit | 256K | chat, coding, reasoning, tool-calling | recommended |
| mistral-small-24b | mlx-community/Mistral-Small-24B-Instruct-2501-4bit | 32K | chat, coding, tool-calling | recommended |
| deepseek-r1-qwen-14b | mlx-community/DeepSeek-R1-Distill-Qwen-14B-4bit | 128K | chat, reasoning | recommended |
| llama-3-1-8b | mlx-community/Llama-3.1-8B-Instruct-4bit | 128K | chat, tool-calling | recommended |
| qwen-2-5-coder-7b | mlx-community/Qwen2.5-Coder-7B-Instruct-4bit | 32K | chat, coding, tool-calling | recommended |
| qwen-2-5-0-5b | mlx-community/Qwen2.5-0.5B-Instruct-4bit | 32K | chat | recommended (starter) |

`*-OptiQ` and the Opus-distilled variants are marked **experimental**. GGUF mirrors mirror their
MLX families. Use-case profiles: general / coding / reasoning / fast / low-memory / best-for-this-mac,
each filtered to the host's safe memory budget.

---

## 7. Onboarding flow (Phase 5)

`esh onboard`: welcome → detect (chip/RAM/macOS/engines/free disk) → **choose storage**
(internal or external SSD) → detect existing models → pick a **use case** (General/Coding/Fast/Best)
→ show hardware-matched recommendations → install → finish with next commands. Non-interactive
`--status` (summary, CI-safe) and `--yes` (auto-install top pick). Re-runnable; versioned state at
`stateRoot/onboarding.json`; never traps experts; no telemetry; explains exactly what's missing if
no engine is ready.

---

## 8. Tests added

41 new tests (suite 130 → 171, all green):
- **Storage** (13): state/assets routing, availability, disconnect/reconnect, wrong-volume marker,
  path-with-spaces, migration, report sizes, `PathResolving`.
- **Doctor** (2): report contents, degraded-on-unavailable-volume.
- **Catalog** (8): well-formedness, unique aliases/sortOrders, GGUF backend, budget-aware
  recommendations, experimental exclusion, coding profile, + **opt-in live-HF** resolution of all 26.
- **Onboarding** (7): state persistence, re-run safety, backend-preference recommendations,
  missing-engine help, env detection.
- **Local import** (5): import MLX dir + GGUF, `--move`, reject-incomplete, scan/discover + orphan
  cleanup safety.
- **Config migration** (6): TOML round-trip, schema default for old configs, JSON back-compat,
  `~/.llmcache` → `~/.esh`, model_dir deprecation.

Optional local integration coverage (documented, not in CI): `ESH_LIVE_HF_TESTS=1` for catalog
resolution; real MLX/GGUF/TTS inference remains a manual smoke (needs models + Metal).

---

## 9. Verification performed

- `swift build` + `swift test` green (171 tests) at every phase boundary.
- Live CLI smoke: `storage set/show/doctor/use-internal` (incl. disconnect→reconnect and a
  path with a space), `doctor --json`, `model info`, `model recommended --for-this-mac`,
  `model import` (MLX dir + GGUF), `model scan --clean`, `onboard --status`.
- All 26 catalog repos verified to resolve on HuggingFace with the expected format.

---

## 10. Known limitations

- **TTS/MLX/GGUF real inference is not automated** in CI (needs model downloads + Metal). TTSMLX
  and mlx-audio upgrades are deferred pending manual TTS validation.
- **Streaming over the HTTP server is buffered**, not incremental (inherited; see baseline §7). Not
  changed here to avoid touching the inference path during stabilization.
- **Checksums**: install verification is byte-count only (upstream HF doesn't always expose hashes).
- `model_dir` is deprecated but still present for backward compatibility.
- Assets migration across volumes copies then removes (no atomic cross-volume move) — safe but not
  instantaneous for very large trees.

---

## 11. Deferred to esh 2.0 (explicitly out of scope)

Per the program's non-goals, these were **not** built: autonomous/multi-agent orchestration, a
large RAG/vector subsystem, a GUI app, broad multimodality, cloud accounts/sync, and a
plugin/marketplace. The onboarding and diagnostic cores were written as reusable services
(`OnboardingService`, `DoctorService`, `StorageService`) so a future GUI or the Ashex agent layer
can consume them without re-implementation. Candidate follow-ups: true incremental HTTP streaming,
TTSMLX 0.7 upgrade with TTS validation, checksum verification where upstream provides hashes, and a
data-file (JSON) catalog override for updates without recompiling.
