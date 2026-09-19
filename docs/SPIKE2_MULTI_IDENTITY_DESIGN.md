# Spike 2 — Two-pass regional multi-identity composition-preserving restyle (design)

Status: **design only** (greenlight-gated on Spike 1 passing its visual gate). No code, no RC, no Esh Studio
change. This is the concrete plan for how Spike 1 (composition-preserving PhotoMaker img2img) becomes the
flagship couple solution.

## Problem recap (proven from code)

PhotoMaker v1 is **single-identity, single fused token** (`num_tokens=1`, one center-cropped 224² CLIP tensor
→ one "person" token; [PhotoMakerV1.swift](../.build/checkouts/mlx-swift-image-edit/Sources/MLXImageEdit/PhotoMakerV1.swift):128,158). It cannot bind two different faces to two subjects — a two-person source blends into one identity. Spike 1 adds
composition preservation (img2img from the source latent) but still shares **one** identity token across all
faces. So Spike 1 alone gives: correct framing + both people *in place*, but not *independently recognizable*.

The only clean-commercial way to preserve **multiple** identities on 32 GB (InsightFace-based InstantID /
IP-Adapter-FaceID / PhotoMaker v2 are all license-excluded) is to run the **single-ID** encoder **once per
detected face**, each on its own crop, and composite by location.

## Architecture

```
source selfie (N people)
  │
  ├─(A) Apple Vision face detection ─────────────► N face boxes (normalized), confidences
  │
  ├─(B) PASS 1: Spike-1 img2img on the WHOLE image (strength ~0.6–0.75, style LoRA)
  │        → base_restyled: composition/pose/background preserved, strong 3D style, faces generic
  │
  └─(C) PASS 2 per face i (sequential, warm-reused UNet):
           crop_src_i   = source face box (expanded margin)      → ID embedding for THIS face only
           crop_base_i  = base_restyled face box (same location) → region to correct (img2img source)
           corrected_i  = PhotoMaker single-ID img2img(crop_base_i, id=crop_src_i,
                                                        strength ~0.35–0.5, style LoRA)
           composite corrected_i back into base_restyled at box_i with a feathered mask
  │
  └─(D) optional harmonize: full-image img2img at very low strength (~0.15–0.2) to blend seams/lighting
  │
  ▼
final artifact  (image.edit → one request → one PNG)
```

Key properties:
- **Multiple identities, no blending:** each face is encoded and corrected independently, then placed at its
  own location. PhotoMaker v1's single-ID limitation becomes a feature (one clean identity per pass).
- **Composition preserved:** Pass 1 img2img anchors the entire layout; Pass 2 only edits face regions inside
  a feathered mask; nothing regenerates the scene from noise.
- **No invented people:** the layout comes from the source latent, not from noise+prompt, which is what
  produced the extra third person in rc.19.
- **Style stays independent:** the same swappable 3D style LoRA is folded in for both passes; identity is the
  ID embedding, style is the LoRA — unchanged separation of concerns.

## Components (all native, in-process, sandbox-safe)

1. **Face detection — Apple Vision `VNDetectFaceRectangles`** (macOS 10.13+/iOS 11+; system framework, no
   model download, no license issue). Returns normalized bounding boxes + confidence + optional roll/yaw.
   Sort boxes left→right for stable per-face naming. This is the "how esh knows multiple identities matter"
   signal (item 5) — a **vision preflight owned by esh**, never the app counting faces.
2. **Pass 1 restyle** — reuse `generateLatentsImg2Img` (Spike 1) at full `size`.
3. **Per-face crop/normalize** — expand each box by ~30–40% (include hair/jaw context), square-crop, resample
   to a face tile (512 or 640). `photoMakerSourceLatentImage` (Spike 1) for the base-region img2img source;
   `photoMakerPreprocess` (existing) for the source-face CLIP ID tensor.
4. **Per-face identity correction** — `generateLatentsImg2Img` on the face tile with that face's ID embedding,
   low strength (~0.35–0.5) so Pass-1 style/lighting is retained while facial features are corrected. Merge
   identity from the first step (`startMergeStep=0..1`) since composition is already fixed.
5. **Feathered compositing** — resize the corrected tile back to the box size; blend into `base_restyled`
   with a cosine/triangular-feather alpha mask (reuse the feather approach already in `decodeTiled`) to avoid
   seams. Composite in pixel space (or latent space if a final decode is deferred).
6. **Harmonize (optional)** — one low-strength full img2img pass to unify seams and global lighting.

## Memory / 32 GB (sequential, warm reuse)

- The UNet + encoders load **once** (~10 GB weights) and are warm-reused across Pass 1 + every Pass-2 face +
  harmonize. **Never two models resident.**
- Pass 1: full 1024 img2img → ~12–13 GB peak (same as Spike 1 / rc.19, measured 12.4 GB).
- Pass 2: face tiles are 512–640 → **lower** peak than Pass 1; run strictly serially.
- Projected overall peak ≈ Pass 1 peak (~12–13 GB). Fits 32 GB with the existing 4 GB MLX cache cap +
  `GPU.clearCache()` between passes. To be **measured** in the Spike 2 build, not assumed.
- Latency projection: Pass 1 (~strength·steps) + N × (short face pass) + optional harmonize. For a couple
  (N=2), roughly Pass 1 + 2 short passes ≈ 1.5–2× a single generation. Report real numbers on build.

## Licensing (hard gate — all clean)

| Component | Code | Weights | Commercial |
|---|---|---|---|
| Apple Vision face detect | system framework | — | ✅ |
| SDXL base | — | OpenRAIL++-M | ✅ |
| PhotoMaker v1 (encoder+LoRA) | Apache-2.0 | Apache-2.0 / OpenCLIP | ✅ |
| 3D style LoRA (goofyai) | Apache-2.0 | Apache-2.0 | ✅ |

No InsightFace, no FaceID, no PhotoMaker v2, no FLUX. Clean for a paid app.

## Public API + routing (no Studio change)

- Public contract stays `image.edit`, one request → one artifact. esh orchestrates the multi-pass chain
  internally (item 19).
- Internal provider: either a new `mlx-photomaker-multi` provider, or an internal multi-face branch inside the
  PhotoMaker provider selected when the **esh** vision preflight detects ≥2 faces **and** the request intent is
  identity stylization. The app sends only the image + scene prompt (unchanged).
- **Routing traits** (item 16) — extend `CapabilityResourceProfile` (rc.20) with generic semantic traits so
  the resource-aware scheduler routes by capability, not by hardcoded model names:
  ```
  identityCapacity: none | single | multi
  compositionPreservation: low | medium | high
  stylizationStrength: low | medium | high
  supportsRegionalConditioning: Bool
  ```
  Then Auto maps: general property edit → IP2P (`identityCapacity none`, composition high);
  single-face identity stylize → PhotoMaker single (Spike 1); multi-face source + identity intent →
  multi-identity pipeline (`identityCapacity multi`, composition high); nothing safe → typed resource gate
  (rc.20). All decisions live in esh.

## Risks + mitigations

- **Seams / lighting mismatch at composite** → feathered masks + low Pass-2 strength + optional harmonize
  pass; composite hair/clothing from Pass 1, correct only facial region.
- **Non-frontal / low-confidence faces** → Vision confidence + yaw gate; below threshold, skip identity
  correction for that face (keep Pass-1 stylization) rather than corrupt it.
- **Small faces** (group photos, distant subjects) → skip identity correction below a min box size; Pass-1
  stylization still applies.
- **Over-correction (uncanny)** → tune per-face strength (0.35–0.5) and merge; sweep like Spike 1.
- **Face count explosion** (large groups) → cap the number of identity-corrected faces (e.g. top-K by size),
  Pass-1 handles the rest. Generalizes 1/2/family/group without a `coupleMode` boolean (item 6).

## Spike 2 validation gate (the real couple test)

Same rubric as Spike 1, on the **actual two-person selfie** (must be supplied), plus:
- both identities independently recognizable (not blended, not swapped);
- exactly two people (no invented third);
- each person in their original position/pose;
- framing/background preserved;
- strong 3D style; safe memory; no visible composite seams.
Pass only if it beats Spike-1-only (which preserves composition but not independent identity).

## Bounded implementation plan (only if Spike 1 passes)

- **Phase A** — Vision face-detect + crop/box utilities + left→right ordering (native, no MLX). Small.
- **Phase B** — Pass 1 wired to Spike 1 img2img; per-face Pass 2 (masked img2img with per-face ID) + feather
  composite; warm reuse across passes. Medium.
- **Phase C** — optional harmonize pass; strength/merge sweep on the couple; memory/latency measurement.
- **Phase D** — provider + traits + rc.20 routing (Auto detects multi-face via esh preflight); esh-level
  dogfood via `ExecutionRequest`; then (separately) Esh Studio.
- Gate between B and C: couple visual gate. Do not proceed to provider wiring until it passes.

## Dependency

Spike 2 **requires** Spike 1's `generateLatentsImg2Img` as its Pass 1 and its per-face engine. Build order is
strict: validate Spike 1 → greenlight Spike 2 Phase A/B → couple gate → Phase C/D.
