# esh SDK — Native Image Generation: Model + Runtime/Packaging Decision

Status: **Decision requested (§4).** Prepared in parallel with native VLM/upscale work. Needs your call on
(1) the base model(s) + license/hosting, and (2) the native runtime/packaging approach — because that same
choice also governs native VLM.

## Why a decision is needed now
- Image generation must ship a real, embeddable, **commercially-licensable** model esh can host + install.
  Per §12, esh must not distribute a model without verified redistribution rights.
- The **runtime choice couples to packaging**: a Core ML pipeline needs *no* SwiftPM dependency (leanest),
  whereas MLX-Swift adds `mlx-swift` (+ swift-transformers graph) to esh's **resolution** graph for *every*
  consumer (built only when the image/VLM product is used). Verified: that graph contains **no swift-syntax**,
  so it does **not** break the rc.3/rc.4 LLM.swift coexistence — but it isn't free for text/Create-only apps.
- Native **VLM** (image understanding) practically requires MLX-Swift (`MLXVLM`); native image gen can go
  either Core ML *or* MLX. So your runtime/packaging choice here decides both.

## Part A — Candidate models

| Model | License | Commercial redistribution | Converted/on-disk size | Device fit | Speed | Runtime | Quality |
|---|---|---|---|---|---|---|---|
| **FLUX.1 [schnell]** (12B) | **Apache-2.0** | ✅ yes, unrestricted | ~8–12 GB (4-bit) / ~24 GB (bf16) | **macOS only** (RAM); not iPhone | Fast (1–4 steps) | MLX (mflux/MLX-Swift); Core ML conversion uncommon/heavy | **Best** |
| **SDXL base 1.0** (2.6B) | OpenRAIL++ (commercial, use-based restrictions) | ✅ with restrictions | ~6–7 GB (Core ML) | macOS; high-end iPhone marginal | Medium (20–30 steps) | **Core ML** (apple/ml-stable-diffusion) or MLX-Swift | High |
| **SDXL-Turbo** (2.6B) | **Stability Non-Commercial research** | ❌ not for a paid app | ~6–7 GB | macOS; iPhone marginal | **Fastest** (1 step) | Core ML / MLX-Swift | High |
| **Stable Diffusion 2.1 base** (0.9B) | CreativeML **OpenRAIL-M** (commercial, use-based) | ✅ with restrictions | ~2–5 GB (Core ML, quantizable) | **iPhone-capable** + macOS | Medium | **Core ML** (Apple-proven on-device) | Good (older) |
| **Stable Diffusion 1.5** (0.9B) | OpenRAIL-M | ✅ with restrictions | ~2 GB (Core ML) | **iPhone-capable** + macOS | Medium | Core ML | Good (older) |

Notes: FLUX.1-**dev** is non-commercial (excluded). SDXL-Turbo/SD-Turbo are non-commercial research licenses
(excluded for a paid Esh Studio). OpenRAIL-M/++ permit commercial use with a use-based acceptable-use clause
(no illegal/harmful use) — standard for shipping SD in apps; legal should confirm acceptability.

## Part B — Runtime / packaging options (governs image gen AND VLM)

1. **Core ML, no SwiftPM dependency (leanest).** Hand-written Core ML pipeline (or apple/ml-stable-diffusion
   as a small dependency) driving converted SD/SDXL `.mlpackage`s. iPhone-proven, smallest footprint, adds
   **nothing** to consumers who don't use imaging. ✗ Doesn't cover VLM (need a converted CoreML VLM, uncommon)
   and no FLUX (conversion heavy).
2. **MLX-Swift (most models).** `mlx-swift-examples` `StableDiffusion` (SD/SDXL/SDXL-Turbo) + `MLXVLM`
   (Qwen2-VL, SmolVLM) → covers image gen AND VLM with one runtime, iOS+macOS, weights from HF. ✗ Adds
   `mlx-swift` (+swift-transformers graph, **no swift-syntax** — coexistence safe) to every consumer's
   resolution graph; heavier build when used.
3. **Hybrid.** Core ML for image gen (lean, iPhone) + MLX-Swift only for VLM (opt-in `EshVision`). Two
   runtimes, but keeps the image path lean and confines mlx-swift to VLM consumers.

## Part C — Recommendation
- **Model:** ship **SD 2.1 base (OpenRAIL-M)** as the iPhone-capable default via **Core ML**, and offer
  **FLUX.1-schnell (Apache-2.0)** as the macOS high-quality option via MLX (already available through the
  compatibility runtime / mflux). This gives a clean commercial license on both tiers and a real iPhone path.
- **Runtime/packaging:** **Hybrid (option 3)** — Core ML for `image.generate` (lean, no dep, iPhone), and
  MLX-Swift confined to the opt-in `EshVision` product for `image.understand` (VLM).
- **Hosting:** convert SD 2.1 base to Core ML, host the `.mlpackage` bundle as a versioned, checksummed
  release asset (same mechanism as the llama.xcframework binaryTarget), install via esh's model catalog with
  Model Fit. FLUX-schnell weights come from HF via the compat runtime.

## Decisions I need from you (then I proceed without further pause)
1. **Image model:** SD 2.1 base (Core ML, iPhone) + FLUX-schnell (MLX, macOS) as recommended? Or a different pick?
2. **License acceptance:** is **OpenRAIL-M** (use-based commercial) acceptable for Esh Studio, or must it be
   strictly **Apache-2.0** (→ FLUX-schnell only, macOS-only, no native iPhone gen for now)?
3. **Runtime/packaging:** Hybrid (Core ML image gen + MLX-Swift VLM), all-MLX-Swift, or Core-ML-only (no native VLM)?
4. **Hosting:** OK to host converted Core ML model assets as esh release assets (checksummed), like the llama binary?

Native VLM implementation is safe to proceed regardless (permissive SmolVLM/Qwen2-VL licenses; mlx-swift graph
verified swift-syntax-free) once you confirm the runtime/packaging approach (option 2 or 3 enables it).

Sources: [FLUX.1-schnell (Apache-2.0)](https://huggingface.co/black-forest-labs/FLUX.1-schnell) ·
[FLUX licensing guide](https://artificialguy.com/blog/flux-licensing-commercial-use/) ·
[apple/ml-stable-diffusion](https://github.com/apple/ml-stable-diffusion) ·
[mlx-swift-examples (MLXVLM / StableDiffusion)](https://github.com/ml-explore/mlx-swift-examples).
