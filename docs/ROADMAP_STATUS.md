# esh Roadmap Status

Live status against the current master roadmap (ClickUp 86eyt96nn) and its addenda. Kept honest:
"done" means implemented, tested, and (for user-facing work) released.

| Milestone | Status | Where |
|---|---|---|
| **M0** Repository Truth & Baseline | ✅ done | docs/STABILIZATION_BASELINE.md |
| **M1** Optimization Foundation | ✅ done (v0.3.0) | Sources/EshCore/Optimization/, OPTIMIZATION_REPORT.md, docs/OPTIMIZATION.md |
| **M2** Dependency & Runtime Modernization | 🟡 partial | swift-syntax 600→603 done; TTSMLX 0.3.3→0.7 and mlx-audio held (need on-device TTS validation) |
| **M3** Storage v2 / External SSD | ✅ done (v0.2.0) | docs/STORAGE.md |
| **M4** Model Lifecycle & Catalog | ✅ done (v0.2.0) + fit gate (v0.3.0) | RecommendedModelRegistry, LocalModelImportService, ModelFitService |
| **M5** First-Run Onboarding + Doctor | ✅ done (v0.2.0) + Apple/fit surfacing (v0.3.0) | OnboardingService, DoctorService |
| **M6** Update System & Living Catalog | 🟡 partial | `esh update check --json` (notify-only) done; channels + refreshable signed catalog pending |
| **M7** Runtime Lifecycle / Warm Pool | ⛔ not started | greenfield |
| **M8** Capability API / Inference Contract v2 | ⛔ not started | ExternalInferenceRequest/Response exist but not the full normalized contract |
| **M8.5** Web Chat | ⛔ not started | depends on M8 |
| **M9** Adaptive Intelligence Scheduler | ⛔ not started | depends on M1 profiles (done) + M8 contract |
| **M10** Local Speech Stack | 🟡 TTS exists; STT stub | AudioCommand/AudioSpeechGenerator |
| **M11** Hardening / 2.0 candidate | ⛔ not started | |

## Mandatory addenda status

- **Apple Foundation Models** — ✅ detection surfaced in doctor/onboarding (v0.3.0); ✅ usable
  on-device generation via `esh apple` (0.4.0-track). Full provider integration into the backend
  registry/contract is deferred to M8 (BackendKind is exhaustively switched; a clean provider
  abstraction belongs in the Capability API).
- **Hard pre-download model-fit gate** — ✅ done (v0.3.0): 6-class fit, soft-override, never
  substitutes; the old memory hard-block was removed.

## Releases

| Version | Contents | State |
|---|---|---|
| 0.2.0 | Stabilization: storage v2, onboarding, catalog, import, doctor --json | ✅ released (notarized + Homebrew cask) |
| 0.3.0 | M1 optimization foundation, model-fit gate, Apple Intelligence detection | released on green CI |
| 0.4.0 (planned) | `esh apple` generation, `esh update check` | staged on branch |

## Next up (recommended order)

1. Ship 0.4.0 (`esh apple`, `esh update check`).
2. **M8 Inference Contract v2** — the normalized request/response the Scheduler and Web Chat need,
   and where Apple/OpenAI/Anthropic become adapters. Large; foundational.
3. **M7 Warm Pool** — loaded-model registry, warm/cold, idle eviction, memory-pressure unload;
   feeds the optimizer's "resident models" input (already modeled in ModelFitService).
4. **M9 Adaptive Scheduler** — combine capability request + fit + M1 benchmark profiles.
5. **M8.5 Web Chat**, **M10 speech**, **M11 hardening**.
