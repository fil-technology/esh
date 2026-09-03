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
| `video.understand` | AVFoundation + VLM + STT + LLM fusion | **experimental** | none | none | ✅ | ✅ | **pipeline runs all 6 steps + typed plan, but the fusion output is unreliable — the resident 3B leaked a control token ("<start_function_call>…") on the test fixture** |

\* production for its typed contract; speaker-count accuracy on very short/synthetic audio is limited.

## Stage 3 verdict

**STAGE 3 NOT COMPLETE.**

Blocking gate:
1. **`video.understand` fusion output is not production-grade.** The multi-step pipeline (keyframe VLM + audio
   STT + LLM fusion) executes end-to-end and returns a typed ExecutionPlan, but the fused summary was
   degenerate this pass (resident-3B control-token leak). It needs: fusion-output sanitization (strip control
   tokens), a more reliable fusion model or the ambiguity-gated Apple path, and a real-content live re-verify
   + persisted benchmark evidence. This was NOT fixed here (out of the image.upscale mission scope).

Everything else Stage 3 requires is met: `image.upscale` is fully production-qualified (2×/4×, storage, Model
Fit, benchmark, cancellation, `/v1/execute`, Web render, natural-chat routing, Router-Auto ambiguity
preserved, broken SeedVR2 not auto-selected), and `image.generate` / `audio.diarize` / `image.ocr` /
`vector.generate` are production with live proof. The one honest gap is video fusion quality.

## To close Stage 3 (follow-up, not started)
- Sanitize `video.understand` fusion output (control-token strip) + route fusion through a reliable model;
  re-verify on real footage; persist upscale-style benchmark evidence.
- Optional: warm-resident upscale runtime (measured ~10 s cold floor is python spawn + CoreML recompile;
  a persistent onnxruntime session integrated with the shared lifecycle manager would cut it — measure the
  benefit before building; do NOT create a separate image-runtime memory manager).
