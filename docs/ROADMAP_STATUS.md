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
| **M11** Hardening / 2.0 candidate | 🟢 rc.7 packaged-validated | 2.0.0 RC program; blockers closed incl. **GGUF packaging** (rc.4: static self-contained `llama-server`), **GGUF runaway** (rc.6: resident `llama-server` + model-native chat template), **MLX runaway** (rc.7: stop at turn/EOS special tokens). rc.7 notarized artifact validated end-to-end — see `docs/RC7_PACKAGED_VALIDATION.md`. **READY FOR FINAL 2.0.** |

## Mandatory addenda status

- **Apple Foundation Models** — ✅ detection in doctor/onboarding; ✅ on-device generation via
  `esh apple`; ✅ first-class backend (`AppleBackend`, reserved ids), on-device-only guarantee enforced
  in the capability contract.
- **Hard pre-download model-fit gate** — ✅ done (v0.3.0): 6-class fit, soft-override, never
  substitutes.
- **No known-broken default/recommended model** — ✅ enforced (2.0 RC Phase B): all MLX Qwen3.5
  (hybrid, crashes on current mlx-lm) reclassified `.incompatible`; flagship default = Mistral Small
  24B; broken Marvis TTS gated. GGUF backend fixed for current llama.cpp (Phase D / blocker B3).

## esh 2.1 — Universal Capability & Modality Runtime (UCMR)

Architecture rule held throughout: **new capability = provider + registration + fit/benchmark + typed
result**, not core surgery. See `UCMR_ARCHITECTURE.md`, `2_1_STAGE3_MODEL_PROVENANCE.md`.

| Stage | Status | Notes |
|---|---|---|
| **Stage 0–1** Runtime + text/SVG/embed/rerank | ✅ done | ExecutionRequest/Result, CapabilityRegistry, ExecutionPlan, `/v1/execute`; language.* + vector.generate + embed/rerank |
| **Stage 2** Input modalities | ✅ done | vision understanding (mlx-vlm), OCR (Apple Vision), segmentation (rembg), capability model resolution, web typed-result rendering — all live-verified |
| **Stage 3** Generation & media | ✅ **complete** (live-validated) | image.generate LIVE (Z-Image-Turbo 4-bit) + Model Fit + benchmarks; **image.upscale LIVE** (Real-ESRGAN ONNX, x2/x4, CoreML — Stage 4.1); video.understand LIVE (AVFoundation pipeline, canonical N-step plan, both branches proven); audio.diarize LIVE (sherpa-onnx, 2 speakers + merged transcript); web image-gen routing + plan inspector. Full suite 431 green; no 2.0 regression. |
| **Stage 4.1** Working upscale backend | ✅ done | Real-ESRGAN ONNX default (SeedVR2 kept experimental); closed the last Stage 3 item |
| **Stage 4.2** Performance-aware Auto / Scheduler v2 | ✅ done (first cut) | `CapabilityPerformanceEvidence` + `CapabilityEvidenceIndex` (adapters over image-gen + LLM benchmark stores) + `CapabilityScheduler` wired into `/v1/execute`: interactive image.generate prefers a within-budget resolution (1024²~215s → 512²~51s), evidence-backed choice folded into the ExecutionPlan. candidateModels enumeration (cross-model ranking) is the remaining follow-up. |
| **Stage 4.3** VLM auto-classification | ✅ done | Install classifies VLMs from config.json (vision_config/model_type/architecture/image-token keys); nanoLLaVA installs as task=vision; image.understand + video.understand resolve a VLM under Auto with no explicit id (models load from local install path). |
| **Capability Intent Router** (86eyucfbu) | 🟢 core done | Tier-0 deterministic router + CapabilityIntent + independent validation + RoutingOutcome (chat/ready/installRequired/clarify/unsupported) + Install-and-Resume (in-memory) + routing benchmark (seed: zero false executions). Tier-1 semantic router (Apple Foundation/FunctionGemma) + Router Auto + product wiring (/v1/route, chat install-card + resume) are the next slices. See `2_1_CAPABILITY_ROUTER_STATUS.md`. |
| **Stage 4.x** (deferred) | ⬜ not started | cross-model candidate enumeration for the scheduler; image editing/inpainting; local video/music generation; remote runtime |

Stage 3 is **complete**: all gate items live-validated, including a working `image.upscale` (Real-ESRGAN
ONNX). SeedVR2 remains as an experimental, non-default backend for future retest.

## Releases

| Version | Contents | State |
|---|---|---|
| 0.2.0–0.9.7 | stabilization → optimization → contract v2 → residency → scheduler → speech → streaming | ✅ released (v0.9.7 latest published: notarized + Homebrew cask) |
| 0.9.8 | real incremental SSE streaming + resident web chat | ⚠️ committed to `main` (VERSION=0.9.8) but **not tagged/published** — reconcile in the 2.0 RC (audit finding A1) |
| 2.0.0 | 2.0 RC program: blockers closed, cross-backend conformance, hardening | 🟢 rc.7 tagged + packaged/notarized-validated (GGUF + MLX runaway fixed, Metal, no-Homebrew self-contained). Ready to promote to final 2.0. |

## Next up

1. Finish the 2.0.0 RC program (Phases H–S in `2_0_RC_AUDIT.md`): docs, security/privacy review,
   API/SemVer contract, stress, and the release candidate.
2. Reconcile the 0.9.8-unpublished version story into the 2.0 line before cutting `2.0.0-rc.1`.
3. M6 signed refreshable catalog; M10 bundle `mlx_audio` verification on the packaged binary.

## Post-rc.3 — URGENT (deferred from the release freeze, do right after the RC ships)

1. **Warm-TTS: hold one long-lived `TTSSpeechSynthesizer`.** TTSMLX ≥0.7.0 already caches loaded models
   (`prepareModel`); esh currently rebuilds the synthesizer per `/v1/audio/speech` call in
   `Sources/esh/AudioSpeechGenerator.swift`, so the cache is never hit (~2 s reload floor per call).
   Requires: (a) bump the dependency to the **fork** so TTSMLX 0.8.0 resolves — esh must declare
   `fil-technology/mlx-audio-swift @exact 0.1.7-tts.1` (not upstream `Blaizzy`, same package identity —
   the root pin wins), and `from: "0.8.0"` for TTSMLX; (b) keep one shared synthesizer + `TTSModelStore`
   across calls, `preload` the configured model on `esh web` start, and call `unloadCachedModels()` under
   memory pressure / on shutdown (respect the unified-memory TTS reserve). Verified locally that the fork
   **resolves** cleanly (`0.1.7-tts.1`, revision `bb5cda2a`, carries `TTSModelRegistry`); the **build**
   needs `.build` on APFS (the ExFAT SSD relocation corrupts git for the new checkouts — needs ~15 GB
   free internal disk, or verify via CI). The esh-side change itself is small and low-risk once it builds.
   The streamed sentence-by-sentence pipeline already shipped as the esh-local speedup.
