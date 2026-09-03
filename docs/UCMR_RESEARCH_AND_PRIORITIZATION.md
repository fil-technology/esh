# esh 2.1 UCMR — Local Apple-Silicon Modality Ecosystem (2026) + Prioritization

Reference hardware: **Apple Silicon, M1 Pro / 32 GB** unified memory, fully local. Verified Sep 2026 against primary sources (HF cards, GitHub, official docs). **Caveat:** much 2026 "benchmark" web content is AI-generated/unreliable — all speeds are directional (**ESTIMATE**) unless marked measured; that is exactly why the "Benchmark First" class exists. Several model names surfaced only in page-summaries and could not be confirmed on canonical cards ("Gemma 4", "MiniMax M3", "Qwen3.5", "DeepSeek-OCR-2", "GLM-OCR", "Falcon-OCR") — **treated as unverified, not adopted.**

Classification: **IMPLEMENT SOON** / **BENCHMARK FIRST** / **RESEARCH ONLY** / **REJECT**.

---

## 13. Findings by capability

### Understanding / retrieval

**Embeddings + reranking — highest value, lowest risk, ZERO new runtime.** The already-bundled `llama-server` (MIT) exposes `/v1/embeddings` (`--embeddings`) and `/rerank` (`--reranking`) **today**.

| Capability | Model | Runtime | License | Size / speed | Class |
|---|---|---|---|---|---|
| embed | **EmbeddingGemma-300M** | llama.cpp (GGUF) | Gemma | 308M, 768-dim Matryoshka→128, <200 MB | **IMPLEMENT SOON** — best open MTEB <500M, on-device-designed |
| embed | **Qwen3-Embedding-0.6B** | llama.cpp | Apache-2.0 | 0.6B, ~1 GB | **IMPLEMENT SOON** — Apache, SOTA family |
| embed | **bge-m3** | llama.cpp | MIT | 568M | **IMPLEMENT SOON** — best multilingual/hybrid |
| embed | nomic-embed-text-v1.5 | llama.cpp | Apache-2.0 | 137M, 8k ctx | IMPLEMENT SOON — light English/long-doc |
| rerank | **bge-reranker-v2-m3** | llama.cpp `/rerank` | MIT/Apache | 568M / 418 MB, **~72 ms/query** | **IMPLEMENT SOON** — the reranker to ship |
| rerank | Qwen3-Reranker-0.6B | llama.cpp | Apache-2.0 | — | **RESEARCH ONLY** — known wrong-score bug (llama.cpp #16407) |

> Avoid `mlx-embeddings` for bundling — **GPL-3.0**. Use llama.cpp embeddings/rerank (no new dep, no copyleft).

**Vision / image understanding** — via **mlx-vlm** (v0.6.17, MIT). Requires adding an image entry point to the MLX bridge (today `mlx_lm`-only).

| Model | License | Size (4-bit) | Speed | Class |
|---|---|---|---|---|
| **Qwen2.5-VL-7B** | Apache-2.0 | ~5 GB / ~7–8 GB peak | ~30–40 tok/s (EST) | **IMPLEMENT SOON** — proven default, best maturity/quality |
| **Gemma 3 4B QAT** (vision) | Gemma | 2.8 GB / **4.4 GB peak** | **66.7 tok/s (measured, rapidmlx)** | **IMPLEMENT SOON** — light/fast option |
| Qwen3-VL-4B/8B | Apache-2.0 | 2.5–5 GB | EST ~30–50 tok/s | **BENCHMARK FIRST** — newest, verify MLX correctness at 0.6.17 |
| Qwen3-VL-30B-A3B | Apache-2.0 | ~18 GB | ~68 tok/s claimed (EST) | **BENCHMARK FIRST** — tight on 32 GB w/ OS+app |
| VLM via llama.cpp mmproj | Apache/Gemma | similar | EST | **BENCHMARK FIRST** — fallback reusing bundled llama-server (`--mmproj`) |

**Document / OCR — two-tier.**
- **Apple Vision `VNRecognizeTextRequest`** — OS-native, free, zero-dep, mature. Strong on printed text/receipts; weak on complex tables. **IMPLEMENT SOON** (plain-text baseline on the Apple stack esh already uses).
- **PaddleOCR-VL (~0.9B, Apache-2.0)** via mlx-vlm — 94.5% OmniDocBench, SOTA layout/tables at tiny size. **BENCHMARK FIRST** (verify MLX port).
- dots.ocr (3B) **BENCHMARK FIRST**; DeepSeek-OCR **RESEARCH ONLY** (niche token-compression, lower plain accuracy).

### Generation / editing

**Image generation** — via **mflux** (MLX). Prefer permissive licenses.

| Model | License | Size | Speed (EST) | Class |
|---|---|---|---|---|
| **Z-Image Turbo** (6B, 4-bit) | **Apache-2.0** | 6.48 GB, 8 steps | ~2–6 s/img | **IMPLEMENT SOON** — best license+speed+size for 32 GB |
| **FLUX.1 schnell** (12B) | **Apache-2.0** | ~12 GB (8-bit) | ~30–60 s | **IMPLEMENT SOON** — proven quality alternative |
| FLUX.2 **Klein 4B** | **Apache-2.0** | ~tight fp | ~30–40 s | **BENCHMARK FIRST** — commercially-clean upgrade path |
| Qwen-Image (20B) | Apache-2.0 | heavy | slow | **BENCHMARK FIRST** — great text-in-image, heavy for 32 GB |
| SDXL-Turbo | OpenRAIL++ / verify Turbo terms | ~3.5B | fast | **BENCHMARK FIRST** — fallback |
| FLUX.1/2 **dev**, SD 3.5 | ⚠ **Non-commercial / thresholded** | — | — | **RESEARCH ONLY / license-gated** |

**Image editing / segmentation — the practical "edit" MVP is segmentation (permissive, tiny, fast):**

| Capability | Model | License | Class |
|---|---|---|---|
| background removal | **rembg** (U2Net/ISNet/BiRefNet) | **MIT** | **IMPLEMENT SOON** — pip-and-go, highest-value edit |
| hi-res matting | **BiRefNet** (~220 MB) | **MIT** | **IMPLEMENT SOON** — best-quality open matting |
| promptable segmentation | **MobileSAM** (~40 MB, ~12 ms/img) | **Apache-2.0** | **IMPLEMENT SOON** — click/box-to-mask UX |
| upscaling | **Real-ESRGAN** (MLX/Core ML) | **BSD-3** | **IMPLEMENT SOON** — mature, permissive |
| instruction editing | **FLUX.1 Kontext** | ⚠ **FLUX Non-Commercial** | **BENCHMARK FIRST / license-gated** |
| instruction editing (commercial) | FLUX.2 Klein / Qwen-Image-Edit | Apache-2.0 | **BENCHMARK FIRST** |

**Audio beyond STT.**
- **pyannote-segmentation-3.0 (MLX, MIT)** diarization/VAD — **IMPLEMENT SOON** (segmentation) / **BENCHMARK FIRST** (full clustering pipeline).
- **MusicGen (MLX)** — ⚠ weights **CC-BY-NC** — **BENCHMARK FIRST / license-gated**. Stable Audio Open — **RESEARCH ONLY** (verify license).

**Video.**
- **Understanding = a pipeline, not one model:** keyframe sampling → VLM (Qwen3-VL, Apache) + audio → existing Whisper/mlx-audio → reasoning. **IMPLEMENT SOON** (as a pipeline; reuses assets we already have).
- **Generation** (LTX/Wan via mlx-video, experimental; LTX Q4 ~19.4 GB) — **REJECT for now** on 32 GB; revisit at 64 GB+ or later.

### Artifact generation + safe preview
- **Text→SVG:** constrained **JSON scene-IR → deterministic Swift renderer** (llama.cpp GBNF for the IR; avoid brittle free-form SVG grammar). **vtracer (MIT)** for image→SVG (avoid potrace/autotrace — GPL). **IMPLEMENT SOON** (architecture proof).
- **Static/interactive preview:** WKWebView secure-static (`<img>`) for SVG; JS-off for static HTML; Claude-Artifacts-style self-contained-HTML + strict CSP (injected by us via custom scheme, not trusting the artifact) + `WKContentRuleList` block-all for interactive single-file. **IMPLEMENT SOON** (tiers 1–3).
- **Managed Node/Next.js preview:** **Apple `container`/Containerization.framework (macOS 26, VM-per-container)** preferred; `sandbox-exec`/Seatbelt + rlimits fallback (deprecated-but-functional). **BENCHMARK FIRST / more design** (tier-4); npm supply-chain: `npm ci` + `ignore-scripts` + npm-12 defaults handle install-time, **but import-time malware needs execution isolation** — stated honestly.

---

## 14. Recommended implementation sequence (evidence-based)

The user's Phase-14 hypothesis started with vision/image understanding. **I recommend a small revision:** prove the *architecture* first with the two lowest-risk, zero-model-download providers, then add real modality models in the user's priority order behind benchmark gates. Rationale: it de-risks every core seam (contract, provider registry, ExecutionPlan, artifact store, `/v1/execute`, typed rendering, preview) **before** taking on model/license/memory complexity, and satisfies most of the release gate as an architecture proof.

**Stage 0 — Core additive contract (no new models).** ExecutionRequest/Result, CapabilityProvider + registry, ExecutionPlan, Artifact + `FileArtifactStore` (`artifactsURL`), `/v1/execute` + `/v1/artifacts/{id}`, typed streaming events, adapters so text/STT/TTS keep working. *(Architecture, not a modality.)*

**Stage 1 — Architecture-proof providers (zero new runtime/deps, permissive):**
1. **Embeddings + Reranking** (bundled llama-server; EmbeddingGemma / Qwen3-Embedding + bge-reranker-v2-m3). Proves capability dispatch, typed non-text output (vector/ranked), fit metrics ≠ tok/s, catalog generalization.
2. **Text → SVG** (JSON-IR → Swift renderer + validator + tier-1 preview). Proves typed **Artifact** end-to-end, blob storage, web typed rendering, safe preview. (Spec's explicit extensibility test.)

> These two are "substantially different non-text providers" (retrieval vs artifact) and need **no** model downloads, GPU diffusion, or license traps — pure architecture proof toward the release gate.

**Stage 2 — First real modality models (high value, mature, permissive), benchmark-gated:**
3. **Vision / image understanding** (mlx-vlm: Qwen2.5-VL-7B + Gemma 3 4B QAT) — needs the bridge image entry point; unblocks OCR + video-understanding.
4. **OCR** — Apple Vision (now) + PaddleOCR-VL (benchmark-first).
5. **Background removal / segmentation** (rembg + BiRefNet + MobileSAM) — the image-edit MVP; adds a small Python/ONNX provider.

**Stage 3 — Generation + heavier pipelines, benchmark-gated:**
6. **Image generation** (mflux: Z-Image Turbo default, FLUX.1 schnell).
7. **Image upscaling** (Real-ESRGAN).
8. **Video understanding** (keyframe→VLM + STT pipeline).
9. **Audio diarization/VAD** (pyannote).

**Stage 4 — Runnable artifacts + preview runtime (after security design):**
10. **Static/interactive WebArtifact** (tiers 1–3 preview).
11. **Managed Three.js/Next.js ProjectArtifact** (tier-4, Apple container preferred).

**Deferred / license-gated / rejected:** FLUX dev/Kontext & SD 3.5 (non-commercial/thresholded); MusicGen/Stable Audio (NC weights) → benchmark-first *for non-commercial* only; **local video generation → REJECT on 32 GB** for now.

**Net change vs the user's hypothesis:** same modality priorities, but inserted a **Stage 0/1 architecture proof** (embeddings + SVG) ahead of vision, so the abstraction is proven before model complexity. Open for the user to override.
