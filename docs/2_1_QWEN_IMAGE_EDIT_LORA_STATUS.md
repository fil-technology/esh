# esh 2.1 — Qwen Image Edit 2511 + generic LoRA (image.edit) — status

**Task:** ClickUp `86eyv38pc` (esh) · consumer `86eyv38qu` (Ashex). **Date:** 2026-09-08. **Machine of record:** Apple Silicon / **32 GB**.

Adds **Qwen-Image-Edit-2511** as a selectable `image.edit` backend with **generic LoRA adapter** support (first validation adapter: a neutral **`3d-animation`** style). This is an extension of the existing production `image.edit` capability (default FLUX.2 Klein 4B), **not** a parallel pipeline or a model-specific API.

## What shipped (code)
- **Generic LoRA wiring** in the mflux bridge (`Tools/mlx_vlm_bridge.py` `image_edit()`): `--lora-paths` / `--lora-scales`, model-agnostic (the base decides compatibility; no adapter hard-coded).
- **`ImageEditOptions`** (backend, model pin, baseModel, loraPaths/scales, seed, steps, guidance, width, height, quantize) — freeform `/v1/execute` options map onto it; the capability contract is unchanged.
- **`ImageAdapter` + `ImageAdapterCatalog`** (`Sources/EshCore/Capabilities/ImageAdapter.swift`): typed adapter independent of the base — id, compatible backend/base, source repo + file, default scale, license, size; neutral aliases; install-path resolver; installed-check. Initial entry `3d-animation` → `prithivMLmods/Qwen-Image-Edit-2511-Pixar-Inspired-3D` / `PI3_20.safetensors` (Apache-2.0). **No brand name in any user-facing id/label** — upstream name kept as diagnostic provenance only.
- **`ImageEditProvider`** resolves a requested adapter → verifies base compatibility (a Qwen LoRA can't attach to FLUX) → resolves the installed LoRA file → applies it, and selects the adapter's recommended base weights. Unknown adapter, incompatible backend, and not-installed all return typed errors. Artifact provenance records the adapter id.
- **Model Fit** (`ImageEditModelFit`): honest per-backend memory model — FLUX.2 Klein comfortable on 32 GB; **Qwen-Image-Edit-2511 tight/unlikely on 32 GB** (surfaced for Scheduler/install-card gating).
- Tests: adapter resolution, alias, unknown/not-installed/incompatible, LoRA on/off, neutral-naming, Model-Fit gating; existing edit/routing tests updated.

## Measured spike (through the RAM-guarded bridge, 512px, 8 steps, staged low-RAM)
| Run | Model | On-disk | Result | Time | Min free RAM |
|---|---|---|---|---|---|
| base | `…2511-mflux-q4` | 29 GB | ❌ RAM guard halted at load | 26 s | 17 MB |
| **base** | `…2511-mflux-q3` | 24.7 GB | ✅ **valid 512×512 PNG** | **~346 s (5.8 min)** | 14 MB |
| base + `3d-animation` LoRA | q3 + `PI3_20` | +0.24 GB | ❌ guard halted at load (×2) | 30–39 s | ~0 (2.4 GB avail) |

**Component sizes (both quants share the encoder):** Qwen2.5-VL text encoder **15.5 GB full-precision** (the anchor), DiT q4 13.2 GB / q3 8.9 GB, VAE 0.24 GB.

## Findings
- **Base Qwen-Image-Edit-2511-q3 runs end-to-end on 32 GB** — but only just: ~5.8 min/edit at 512px, running against the memory ceiling via compression. Not a comfortable/fast path.
- **q4 does not fit 32 GB**; the 15.5 GB full-precision text encoder is identical across quants, so smaller quants only shrink the DiT.
- **The generic LoRA path is validated** (mflux accepts `--lora-paths` and enters model load), but **base + LoRA is ~1–2 GB short of completing on this loaded 32 GB Mac** (apps hold ~10 GB) — the guard correctly halts it. It needs a couple GB freed (close an app) or a >32 GB machine; resolution changes don't help (weights dominate).
- **RAM guard works correctly throughout** — no panic on any over-subscription.

## Bake attempt (option 1 — quantize the encoder + merge LoRA via `mflux-save`, guarded)
Added a RAM-guarded `image-edit-bake` bridge command (wraps `mflux-save --quantize --lora`). Measured on 32 GB:
- Bake from the q3 snapshot @ q4 → 27 GB (text_encoder 13 GB, transformer 14 GB); @ q3 → 27 GB (encoder 13 GB, transformer 14 GB).
- **`mflux-save` does NOT meaningfully quantize the Qwen2.5-VL text encoder (~13 GB floor)**, and baking from an already-quantized snapshot *bloats* the DiT. A proper small snapshot needs baking from the **fp original (40 GB)**, but `mflux-save` **loads the whole model** (the bake hit 14 MB free loading 24.7 GB — no streaming), so it can't run on 32 GB.
- **Net: option 1 does not rescue 32 GB.** The ~13 GB VL text encoder is a hard mflux floor; base+LoRA (~26 GB) + the unkillable ~5 GB Claude app exceeds the guard's safe ceiling.

## ✅ 32 GB path VALIDATED (option A) — FLUX.2 Klein + 3D LoRA
The generic LoRA path is now **validated end-to-end on 32 GB** with a commercial-safe combo, and wired as the
default `3d-animation` adapter:
- Base **FLUX.2 Klein 4B** (esh's default edit backend, Apache-2.0, ~5 GB peak) + LoRA
  **`Latentiq/Flux2_Klein_4B_3D2AI_LoRA`** (`Flux_Klein_4B_3D2AI_BF16_R16.safetensors`, 46 MB, **Apache-2.0**).
- Measured: `image.edit` backend=flux2-klein + `--lora-paths`, 768px, **rc=0, ~131 s**, valid PNG; the LoRA
  output differs from the no-LoRA Klein edit by ~93/255 per channel (adapter is genuinely applying).
- Catalog: **`3d-animation` → FLUX.2 Klein path** (validated, 32 GB, commercial-safe). The Qwen path is kept as
  **`3d-animation-max`** (backend qwen-edit) — SUPPORTED but NOT validated on 32 GB (needs >32 GB; see below).

## Verdict / recommendation
- **Default `image.edit` stays FLUX.2 Klein 4B** (Apache-2.0, comfortable on 32 GB). **Qwen-Image-Edit-2511 is a documented opt-in** for machines with headroom — Model Fit reports it tight/unlikely on 32 GB and the base+LoRA needs ~2 GB more free than a fully-loaded 32 GB Mac has.
- **Generic LoRA/adapter architecture is complete and tested**, ready for any Qwen-Image-Edit adapter (add a catalog entry, no code change).
- **To finish the live LoRA benchmark:** re-run with ~2 GB more free RAM (close a heavy app) or on a >32 GB / CI Apple-Silicon host. Reproduction: `image.edit` via `/v1/execute` with `options.adapter = "3d-animation"`.
