# MLX-Swift 0.31 migration — dependency audit (Priority 1, Phase A/B)

Branch: `migration/mlx-swift-0.31` (off `research/extreme-local-inference`). Goal: let the **macOS** package
(+`esh` CLI + macOS `MLXBackend`/server `LlamaCppBackend`) build, preserving text/vision/image/audio. This
documents the current graph, the attempted migration, and the **exact blocker** that stops it (per the directive:
stop + document rather than remove functionality).

## Current constraints (before migration)

| Package | Current pin | Requires mlx-swift | Requires swift-transformers | Notes |
|---|---|---|---|---|
| root `mlx-swift` | upToNextMinor 0.29.1 | 0.29.x | — | direct (EshImageGen `MLX`) |
| root `mlx-swift-examples` | exact 2.29.1 | 0.29.x | 1.0.x | StableDiffusion (EshImageGen) + MLXVLM/MLXLMCommon (EshVision) |
| root `mlx-swift-image-edit` | exact 0.2.0 | 0.29.x | 1.0.x | InstructPix2Pix/PhotoMaker (EshImageGen) |
| root `swift-transformers` | upToNextMinor 1.0.0 | — | self | `Hub` |
| macos `TTSMLX` | from 0.3.3 | **≥0.30.6** (0.7.0+ → 0.31.5) | (via mlx-audio) | on-device TTS; esh imports `TTSMLX` |
| macos `mlx-audio-swift` | revision c96fe7b (transitive of TTSMLX) | **≥0.30.6** | (via mlx-swift-lm) | audio codecs/STT |

**Conflict 1 (mlx-swift):** TTSMLX (≥0.30.6) vs root 0.29.x → the original build failure. **Resolvable:** bump
root to mlx-swift 0.31.6 (TTSMLX 0.3.3 accepts it; so do image-edit's 0.31 branch and examples main).

## Attempted migration (spike config applied to current root)

Applied the proven `spike/mlx-swift-0.31-flux2` dependency set to root `Package.swift`:

```
mlx-swift            : upToNextMinor(from: "0.31.6")
mlx-swift-examples   : revision 378f2449…  (main; MLXMNIST + StableDiffusion; LLM/VLM split into mlx-swift-lm)
swift-transformers   : upToNextMajor(from: "1.3.0")
mlx-swift-image-edit : path "../mlx-swift-image-edit"   (its spike/mlx-swift-0.31 branch, requires mlx-swift 0.31.6)
```

`swift package resolve` on the **root** package succeeds. On the **macOS** package it progresses further than
before — **mlx-swift resolves cleanly at 0.31.6** — then fails on a new, deeper conflict.

## BLOCKER (Conflict 2 — swift-transformers) — exact resolver output

```
'mlx-audio-swift' depends on 'mlx-swift-lm' 2.30.3..<3.0.0 and
'mlx-swift-examples' depends on 'swift-transformers' 1.3.0..<2.0.0.
'mlx-swift-lm' 2.31.3 depends on 'swift-transformers' 1.2.0..<1.3.0;
other mlx-swift-lm versions depend on 1.1.6..<1.2.0.
```

- **image/vision side:** `mlx-swift-examples` main (`378f2449`) → **swift-transformers ≥1.3.0**. EshImageGen
  (StableDiffusion) and EshVision (MLXVLM) need examples on mlx-swift 0.31.x, and the only 0.31.x examples
  revisions available require 1.3.0.
- **audio side:** `mlx-audio-swift` → `mlx-swift-lm` (≤2.31.x) → **swift-transformers <1.3.0** (2.31.3 → 1.2.x).
- **Disjoint ranges → no common swift-transformers version with the current published revisions.** This is
  package-level (manifest) resolution, so it fails even though no single target uses both sides; the root
  manifest declaring `mlx-swift-examples` forces its resolution into the macOS graph alongside `mlx-swift-lm`.

This is the same wall the spike hit: it proved **root-only** builds on 0.31.6 (and moved EshVision to `macos/`),
but the **full macOS graph with audio** (mlx-audio-swift → mlx-swift-lm) was never resolved — hence "EshVision
unwired / incomplete".

## Resolution options (none is a trivial pin change; each needs upstream alignment or restructuring)

1. **Find an `mlx-swift-examples` revision on mlx-swift 0.31.x that uses swift-transformers 1.2.x** (to match
   `mlx-swift-lm` 2.31.3's `1.2.0..<1.3.0`). Pin swift-transformers to `1.2.x`. If StableDiffusion/MLXVLM on that
   revision compile, the whole graph resolves. *Requires archaeology of the examples commit history.*
2. **Bump the audio side** to an `mlx-audio-swift`/`mlx-swift-lm` release that accepts swift-transformers 1.3.0.
   None exists today (all mlx-swift-lm ≤2.31.x want <1.3.0). *Requires an upstream release.*
3. **Decouple image-gen (examples) from the audio graph** via SwiftPM **package traits** so `mlx-swift-examples`
   is only resolved when the image/vision products are actually selected — so a CLI build that needs audio but
   not image-gen doesn't pull examples. *Non-trivial manifest work; may still clash if both are ever needed.*
4. **Replace the examples dependency for StableDiffusion** with `mlx-swift-image-edit`'s graph (already on 0.31.6
   + transformers 1.3) IF it can also provide SD — unlikely without adding SD there. *Scoped.*

## Recommendation / status

- **Conflict 1 (mlx-swift 0.29→0.31) is solved** by the bump above.
- **Conflict 2 (swift-transformers 1.3 vs <1.3) is the hard blocker** and cannot be resolved by pin changes with
  the current published upstream revisions, without dropping image-gen (examples) or audio (mlx-swift-lm) — which
  the directive forbids. **Stopped here and documented** rather than remove functionality.
- Most promising next step: **Option 1** (locate an examples 0.31.x revision on transformers 1.2.x) — a focused
  upstream-revision hunt + a compile check of EshImageGen/EshVision against it. Tracked in ClickUp `z8xxqw8y07` #1.
- The migration branch baseline is kept clean (Package.swift reverted); the attempted config is recorded above so
  it can be re-applied the moment a compatible examples/transformers/lm revision set is identified.

## What this unblocks once solved

- macOS `esh` CLI + macOS `MLXBackend` build → **real-weight 30B through the esh macOS runtime** (Phase C #5),
  plus the macOS server `LlamaCppBackend` path for the 80B.
