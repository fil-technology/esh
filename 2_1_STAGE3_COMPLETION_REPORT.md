# esh 2.1 — Stage 3 (Generation & Richer Media) completion report

Determination pass focused on production-qualifying `image.upscale`, then auditing every Stage 3 capability
against real, re-verified evidence (not prior reports). Mac: Apple M1 Pro / 32 GB, macOS 26.5.1. HEAD at
audit: `41f53a1` (branch `main`). Full suite: **489 green**. Assets root: external SSD (1.18 TB free).

## `image.upscale` — production-qualified this pass

- **Provider**: `ImageUpscaleProvider` → `ImageUpscaleService` → Real-ESRGAN ONNX on **onnxruntime**
  (CoreML EP + CPU fallback). Model `SceneWorks/real-esrgan-onnx` **pinned @09f741b**, on SSD
  `caches/upscale-models`. SeedVR2 remains an **experimental** backend, never auto-selected.
- **Scales**: native **2×** and **4×** (separate model files); other values honestly rejected. Effective =
  native (no hidden post-resize); metadata exposes `nativeScale`/`effectiveScale`.
- **Correctness/robustness**: **alpha preserved** (RGB through the model + LANCZOS alpha, recomposed);
  **tiling with overlap + size-aware memory guard** for large inputs (bounds peak memory, no OOM);
  corrupt/unsupported input → typed execution error (not a generic failure).
- **Cancellation**: `ProcessRunner.runCancellable` / `MLXBridge.runCancellable` terminate the helper
  (SIGTERM→SIGKILL) on cancel — no orphan worker (unit-tested; live: no orphan procs after runs).
- **Model Fit**: `ImageUpscaleFitService` separates **memory fit** from **expected latency**, both from
  measured evidence ("memory fit does not imply interactive speed"); surfaced in the Execution Inspector.
- **Benchmark evidence** (persisted, unified `CapabilityPerformanceEvidence`):

| Input | Scale | Cold | Warm | Peak mem | Output | Verdict |
|---|---|---|---|---|---|---|
| 512² | 2× | 8.7 s | 7.1 s | 3.1 GB | 1024² | interactive-ish |
| 512² | 4× | 11.7 s | 11.8 s | 10.1 GB | 2048² | usable |
| 1024² | 2× | 11.1 s | 11.0 s | 3.6 GB | 2048² | usable |
| 1024² | 4× | 24.2 s | 24.1 s | 12.0 GB | 4096² | heavy but fits |
| 2048² | 2× | 26.8 s | 26.8 s | 8.4 GB | 4096² | heavy (tiled) |

  Cold ≈ warm — **no warm reuse today** (each call cold-spawns python + recompiles the CoreML model).
- **Live-verified** via `/v1/execute` and the **real Web UI**: 2×/4×, 800 px tiling, RGBA alpha preserved,
  inline render + **download** + Execution Inspector; **"Make this better" → clarify** (Router Auto ambiguity
  gate preserved — no auto-upscale). Install-and-Resume covered by router unit tests (requirement =
  `real_esrgan_x4.onnx`; in-memory pending, known limitation).

## Stage 3 capability matrix (re-verified this pass unless noted)

| Capability | Provider | Status | Fit | Benchmark | Web/API | Routing | Limitation |
|---|---|---|---|---|---|---|---|
| `image.upscale` | Real-ESRGAN ONNX | **production** | ✅ perf-aware | ✅ measured | ✅ | ✅ | no warm reuse (~10 s floor); 4×/large is heavy |
| `image.generate` | mflux Z-Image Turbo | **production** | ✅ image fit | ✅ measured (on disk) | ✅ | ✅ | slow at 1024² (GPU-bound); not re-run this pass (has evidence) |
| `image.ocr` | Apple Vision | **production** | n/a (no model) | n/a | ✅ | ✅ | small-font misreads (re-verified live this pass) |
| `vector.generate` | LLM→JSON→SVG | **production** | n/a | n/a | ✅ | ✅ | small models need Apple-FM escalation (live-verified prior) |
| `audio.diarize` | sherpa-onnx | **production*** | none | none | ✅ | ✅ | clustered 2 synthetic TTS voices as 1 (re-verified live: typed JSON + transcript + timestamps) |
| `image.understand` | nanoLLaVA (mlx-vlm) | production | none | none | ✅ | ✅ | quality bounded by the 4-bit VLM |
| `image.segment` | rembg | production | none | none | ✅ | ✅ | optional dependency |
| `language.embed` / `rerank` | llama-server | production | n/a | n/a | ✅ | n/a | requires an explicit embedding/rerank model |
| `video.understand` | AVFoundation + VLM + STT + LLM fusion | **production** | none | none | ✅ | ✅ | fusion now prefers Apple Intelligence + sanitizes control tokens (fixed); no perf benchmark evidence yet |

\* production for its typed contract; speaker-count accuracy on very short/synthetic audio is limited.

## Stage 3 verdict

**STAGE 3 COMPLETE.**

The blocking gate — `video.understand` fusion output quality — is **fixed**: the fusion step now prefers
**Apple Intelligence** (reliable, no control-token leaks), falls back to the resident model, **sanitizes**
special/control tokens (`<|..|>`, `<start_function_call>`, `<eos>`, `<0x..>`, reasoning tags), and detects
degenerate output (escalating, or failing honestly rather than emitting garbage). Live-verified on the same
fixture that previously produced `<start_function_call>kommen` — now a clean coherent summary via
apple-intelligence.

All Stage 3 required capabilities are production:
- `image.upscale` — fully production-qualified (2×/4×, storage, perf-aware Model Fit, measured benchmark,
  cancellation, `/v1/execute`, Web render + download + Inspector, natural-chat routing, Router-Auto ambiguity
  preserved, SeedVR2 experimental-only/never auto-selected).
- `image.generate` — production (measured evidence on disk; live-proven prior).
- `audio.diarize` — production (re-verified live: typed JSON + transcript + timestamps).
- `video.understand` — production (pipeline + reliable fusion; re-verified live).
- plus `image.ocr` (Apple Vision), `vector.generate`, `image.understand`, `image.segment`,
  `language.embed`/`rerank` — all production/functional.

## Remaining follow-ups (not blocking; not started)
- Persist upscale-style benchmark evidence for `video.understand` (perf/latency per clip length).
- Warm-resident upscale runtime — the measured ~10 s cold floor is python spawn + CoreML recompile; a
  persistent onnxruntime session integrated with the **shared** lifecycle manager would cut it. Measure the
  benefit before building; do NOT create a separate image-runtime memory manager.
- Improve `audio.diarize` speaker separation on very short/synthetic audio.
- Durable (restart-surviving) Install-and-Resume pending invocations.
