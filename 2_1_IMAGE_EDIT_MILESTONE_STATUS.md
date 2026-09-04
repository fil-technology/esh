# esh 2.1 — Image Editing & Transformation milestone: status = EXPERIMENTAL (not production)

Goal: `image + instruction → image` as a first-class Universal Capability. Mac: Apple M1 Pro / 32 GB,
macOS 26.5.1. Full suite: **498 green**.

## Architecture + safety — DONE and proven
- **No core surgery.** `image.edit` already existed in the capability contract; `CapabilityInput` already
  carried image + text(instruction) + attachment(mask/reference) + roles. Adding the capability was exactly
  **provider + metadata + routing + fit + rendering** — the architectural rule holds.
- **One coherent capability** `image.edit` (the operation rides in the instruction), not a fan-out of
  inpaint/outpaint/restyle/relight. Background removal stays `image.segment` (router picks by intent).
- **Provider + bridge**: `ImageEditProvider` → `ImageEditService` → mflux edit CLIs. Backends: `qwen-edit`
  (Qwen-Image-Edit, Apache-2.0, default/commercial-safe) and `kontext` (FLUX.1 Kontext, non-commercial,
  opt-in). Typed ImageArtifact with **license/commercial/model provenance** + source-artifact lineage.
- **Guarded execution — validated live**: runs only through `/v1/execute` (never the raw CLI), killable,
  `--low-ram` + VAE tiling + a memory floor. The **RAM guard killed a 768² run at 4.3 GB free to protect the
  machine** — the safety that (when bypassed by a raw CLI run) had caused a watchdog-timeout kernel panic.
- **Routing**: concrete edit instructions → `image.edit`; "remove the background" → segment; "make this
  better" → clarify. Tier-0 false-exec still **0** on the frozen dataset (Router Auto safety preserved).
- **Install-and-Resume detection**, Model-Fit requirement, Tier-1 schema, Web **before/after compare**, and
  unit tests all in place.

## Why it is NOT production on this 32 GB Mac — the model reality

| Model | License | Fits 32 GB? | Accessible? | Output |
|---|---|---|---|---|
| Qwen-Image-Edit-2509 (default) | Apache-2.0 | **No** (~40 GB / 20 B → the RAM guard would kill it) | Yes (open) | not reachable (too heavy) |
| FLUX.1-Kontext-dev (official, best) | non-commercial | borderline (24 GB→4-bit, 512² only) | **No — GATED** (needs HF license acceptance + token) | not reachable |
| Community 4-bit Kontext (`mzbac/…mlx`) | non-commercial | Yes (~9 GB) | Yes | **garbage** — loads in mflux without error but produces tiled/noisy output (silent format incompatibility with mflux's Kontext loader) |

Live-verified: the community 4-bit model produced broken output on BOTH a synthetic image AND a real
photorealistic image (esh-generated) — so it's the model/backend, not the input. The official model is gated
(license + credentials required — must be the user's action, not the agent's). The open commercial-safe model
is too heavy for 32 GB. And `--low-ram` (the only way to fit) makes editing **impractically slow (~20 min at
768², which then gets guard-killed anyway; 512² completes but slowly)**.

**Net:** no working + memory-feasible + accessible image-edit path exists on this 32 GB Mac without either
(a) the user accepting the FLUX Kontext license on HuggingFace and providing an `HF_TOKEN`, or (b) more RAM
for the open heavy models. The capability is real, safe, and wired — the blocker is model access + hardware.

## Verdict: `image.edit` = **EXPERIMENTAL**
Production gate (Phase 15) NOT met: no production-quality output achievable here. Preserved honestly: the
capability runs safely and end-to-end; it just needs a working+accessible model.

### To reach production (user/hardware actions, not code)
- Accept the FLUX.1-Kontext-dev license on HuggingFace + set `HF_TOKEN` → official mflux-native Kontext
  (correct output; run at 512² with `--quantize 4` + `--low-ram`, still slow), OR
- Run on a higher-RAM Mac (≥64 GB) → Qwen-Image-Edit (Apache-2.0) or full Kontext at usable speed, OR
- Wait for a lighter high-quality mflux-native instruction-edit model.
