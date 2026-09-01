# esh Roadmap Status

Live status against the master roadmap (ClickUp 86eyt96nn) and its addenda. Kept honest: "done" means
implemented, tested, and (for user-facing work) released. Last reconciled: **2026-09-01**, during the
2.0.0 RC program (see `2_0_RC_AUDIT.md`).

| Milestone | Status | Where |
|---|---|---|
| **M0** Repository Truth & Baseline | ✅ done | docs/STABILIZATION_BASELINE.md |
| **M1** Optimization Foundation | ✅ done (v0.3.0) | Sources/EshCore/Optimization/, OPTIMIZATION_REPORT.md |
| **M2** Dependency & Runtime Modernization | 🟡 partial | swift-syntax done; on-device TTS shipped (Soprano); Marvis gated (broken) |
| **M3** Storage v2 / External SSD | ✅ done (v0.2.0) | docs/STORAGE.md |
| **M4** Model Lifecycle & Catalog | ✅ done | RecommendedModelRegistry, LocalModelImportService, ModelFitService |
| **M5** First-Run Onboarding + Doctor | ✅ done | OnboardingService, DoctorService |
| **M6** Update System & Living Catalog | 🟡 partial | `esh update check --json` (notify-only) done; signed refreshable catalog pending |
| **M7** Runtime Lifecycle / Warm Pool | ✅ done | RuntimeLifecycleManager, RUNTIME_LIFECYCLE_REPORT.md; persistent MLX residency verified (~10× warm) |
| **M8** Capability API / Inference Contract v2 | ✅ done | CapabilityResolver, InferenceContractV2, M8_CONTRACT_REPORT.md; conformance suite green |
| **M8.5** Web Chat | ✅ done (server-verified) | WebChatPage.swift, `esh web`; rich ChatGPT-like UX. Live-browser interaction env-limited |
| **M9** Adaptive Intelligence Scheduler | ✅ done | SchedulerService; measured-evidence routing verified (skips broken models) |
| **M10** Local Speech Stack | 🟡 TTS done; STT wired | AudioSpeechGenerator (TTS verified), SpeechToTextService + `/v1/audio/transcriptions` (plumbing verified; transcription needs bundled mlx_audio) |
| **M11** Hardening / 2.0 candidate | 🟡 in progress | 2.0.0 RC program (`2_0_RC_AUDIT.md`); blockers B1/B2/B3 closed; docs/security/stress/RC pending |

## Mandatory addenda status

- **Apple Foundation Models** — ✅ detection in doctor/onboarding; ✅ on-device generation via
  `esh apple`; ✅ first-class backend (`AppleBackend`, reserved ids), on-device-only guarantee enforced
  in the capability contract.
- **Hard pre-download model-fit gate** — ✅ done (v0.3.0): 6-class fit, soft-override, never
  substitutes.
- **No known-broken default/recommended model** — ✅ enforced (2.0 RC Phase B): all MLX Qwen3.5
  (hybrid, crashes on current mlx-lm) reclassified `.incompatible`; flagship default = Mistral Small
  24B; broken Marvis TTS gated. GGUF backend fixed for current llama.cpp (Phase D / blocker B3).

## Releases

| Version | Contents | State |
|---|---|---|
| 0.2.0–0.9.7 | stabilization → optimization → contract v2 → residency → scheduler → speech → streaming | ✅ released (v0.9.7 latest published: notarized + Homebrew cask) |
| 0.9.8 | real incremental SSE streaming + resident web chat | ⚠️ committed to `main` (VERSION=0.9.8) but **not tagged/published** — reconcile in the 2.0 RC (audit finding A1) |
| 2.0.0 | 2.0 RC program: blockers closed, cross-backend conformance, hardening | 🟡 in progress on `codex/web-chat-rich` |

## Next up

1. Finish the 2.0.0 RC program (Phases H–S in `2_0_RC_AUDIT.md`): docs, security/privacy review,
   API/SemVer contract, stress, and the release candidate.
2. Reconcile the 0.9.8-unpublished version story into the 2.0 line before cutting `2.0.0-rc.1`.
3. M6 signed refreshable catalog; M10 bundle `mlx_audio` verification on the packaged binary.
