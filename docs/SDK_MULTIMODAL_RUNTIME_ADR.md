# ADR — §3 Multimodal Runtime Direction for the esh SDK

Status: **Proposed — awaiting approval. No §3 implementation started.**
Date: 2026-09-16 · Scope: image generation/editing, vision understanding, audio (SFX)/music, and the
adjacent segmentation/upscale/diarization providers. Decision requested before any §3 wiring.

## 1. Context

rc.6/rc.7 exposed the portable capability facade (`execute`/`stream`/`capabilityAvailability`/`makeDefault`)
and wired every capability whose implementation is already portable: text, OCR, SVG, Website, Code, and
on-device speech (STT/TTS). The remaining §3 families (image gen/edit/upscale/segment, vision & video
understanding, audio SFX, music) exist in esh **only** inside `EshMacRuntime`, and every one of them runs
through **`MLXBridge` — a Python subprocess** (`bridge.run` over JSON stdin/stdout) invoking mflux /
mlx-vlm / rembg / Real-ESRGAN(ONNX) / AudioGen / MusicGen.

That Python dependency is the blocker: a consumer app (Esh Studio) cannot reach these through the SDK
without the app itself bundling and managing a Python environment (mflux, mlx-vlm, onnxruntime, torch-class
deps, model caches). That is heavy, fragile, App-Store-hostile, and impossible on iOS.

## 2. Decision to make

What runtime should back §3 capabilities **in the SDK** (what a consumer app links), given the goal:

> The SDK must not require consumer apps to bundle/manage a Python environment **if a practical
> native/in-process implementation exists.** Keep the existing Python-backed implementations for the esh
> CLI / macOS developer runtime while native SDK providers are evaluated and built.

## 3. Options

**A. Status quo — Python/MLX bridge in the SDK.**
Reuse the proven mflux/mlx-vlm/etc. via `MLXBridge`. ✗ Requires shipping Python to consumers; ✗ not
iOS-viable; ✗ large/fragile. Rejected for the SDK (retained for the CLI/dev runtime — see §5).

**B. Native MLX-Swift, in-process.** `ml-explore/mlx-swift` (+ `mlx-swift-examples`) provides Swift
libraries running MLX on-device with **no Python**: `MLXVLM` (Qwen2-VL, PaliGemma — vision understanding),
`StableDiffusion` (SD / SDXL-Turbo — image generation), embeddings. Runs on iOS + macOS + visionOS.
mlx-swift is already in esh's macOS dependency graph (via TTSMLX/mlx-audio) and does **not** pull
swift-syntax, so it doesn't touch the rc.3/rc.4 coexistence. ✓ In-process, ✓ iOS-capable, ✓ flexible model
set; ✗ heavier binary/memory, ✗ fewer models ported than the Python ecosystem (no FLUX/Qwen-Image-Edit
Swift port today), ✗ downloads weights at runtime.

**C. Apple-native frameworks + Core ML, in-process.** First-party, smallest footprint, best iOS story, **no
third-party runtime**:
- Vision `VNGenerateForegroundInstanceMaskRequest` → **background removal / segmentation, natively**
  (iOS 17 / macOS 14). Replaces rembg outright.
- `apple/ml-stable-diffusion` (Core ML Swift package) → **image generation** in-process (iOS 16.2+/
  macOS 13.1+; Python used only for one-time model conversion, never at runtime).
- Core ML–converted Real-ESRGAN, or MetalFX spatial upscaling → **upscale**.
- Apple **Image Playground** (`ImageCreator`, iOS 18.1+/macOS 15.1+) → image gen with zero model management
  (limited control/styles).
- Core Image → deterministic **image edits** (filters, crop, composite, inpaint scaffolding).
✓ Native, ✓ smallest, ✓ iOS-first; ✗ less model/control breadth, ✗ conversion effort, ✗ no native
SFX/music path.

**D. Layered hybrid (recommended).** Native SDK providers wherever a practical in-process path exists
(Options B/C), behind **opt-in capability products** so text-only consumers don't pull the weight; keep the
Python bridge **only** in the esh CLI / macOS dev runtime for capabilities without a mature native path yet,
surfaced to consumers honestly via `capabilityAvailability()` (`unsupportedOnPlatform` / `comingLater`)
rather than by shipping Python.

## 4. Per-capability native feasibility

| Capability | Today (Python) | Native in-process option | iOS? | Effort | SDK target |
|---|---|---|---|---|---|
| image.segment / bg-removal | rembg | **Vision foreground-mask** (native, no dep) | ✅ | Low | **Native now** |
| image.upscale | Real-ESRGAN ONNX | Core ML Real-ESRGAN / MetalFX | ✅ | Low–Med | **Native** |
| image.generate | mflux (FLUX/Z-Image) | Core ML `ml-stable-diffusion` **or** MLX-Swift SD/SDXL-Turbo | ✅ | Med | **Native** (CoreML first) |
| image.understand (vision) | mlx-vlm | MLX-Swift `MLXVLM` (Qwen2-VL) | ✅ | Med | **Native (MLX-Swift)** |
| image.edit | Qwen-Image-Edit / FLUX Kontext | Core Image (deterministic) now; instruct-edit native port immature | ⚠️ | High | Partial native + dev-Python |
| video.understand | AVFoundation + mlx-vlm | AVFoundation (native) + MLX-Swift VLM per-frame | ✅ | Med–High | Native (composed) |
| audio.generate (SFX) | AudioGen | no mature native Swift/CoreML port | ✗ | High | **Dev/Python only** for now |
| music.generate | MusicGen | MLX port nascent; CoreML heavy | ✗ | High | **Dev/Python only** for now |
| audio.diarize | sherpa-onnx | Core ML / on-device speaker models (research) | ⚠️ | High | Dev/Python only for now |

## 5. Recommendation

Adopt **Option D**, sequenced by native readiness:

1. **Quick native wins (no new heavy deps):** `image.segment` via Vision, `image.upscale` via Core ML/
   MetalFX, deterministic `image.edit` via Core Image. These can be **portable providers in a small opt-in
   product** (iOS + macOS), zero Python, minimal footprint.
2. **Native generators/understanding:** `image.generate` via Core ML `ml-stable-diffusion` (smallest, no
   third-party runtime) with MLX-Swift SD as an alternative; `image.understand` via MLX-Swift `MLXVLM`.
   Ship behind an **opt-in `EshImaging` / `EshVision` product** so text/Create-only consumers stay lean and
   the swift-syntax/LLM.swift coexistence is untouched (neither Core ML nor mlx-swift pulls swift-syntax).
3. **Defer (no native path yet):** `audio.generate`, `music.generate`, advanced instruct-`image.edit`,
   `audio.diarize`. Keep them in the **esh CLI / macOS developer runtime on the Python bridge**, and have
   the SDK report them honestly via discovery (`comingLater` / `unsupportedOnPlatform`) — never ship Python
   to a consumer for them.

Net effect: most of §3 (segmentation, upscale, image gen, vision, video-understanding) becomes reachable by
Esh Studio **in-process, no Python, and iOS-capable** — a materially better outcome than the earlier
assumption that §3 required a Python-bearing macOS-only product. The Python implementations stay intact for
the CLI/dev runtime.

## 6. Packaging shape

- New opt-in product(s), e.g. `EshImaging` (image gen/edit/upscale/segment) and `EshVision`
  (image/video understanding), depending on `EshCore` + Core ML (system) and/or `mlx-swift` — **not**
  swift-syntax, **not** TTSMLX. A consumer adds them only if it wants those modes; `EshRuntime`/`EshLlamaCpp`
  stay lean. `makeDefault` gains an overload (in those products) that registers the native providers.
- `EshMacRuntime` (CLI/dev) keeps its Python-bridge providers unchanged.

## 7. Risks / open questions (for approval)

1. **Model conversion & hosting** — Core ML SD needs converted `.mlpackage`s; who hosts them (like the
   llama binaryTarget), and which base model(s)? MLX-Swift downloads MLX weights from HF at runtime.
2. **Binary/memory** — SD/VLM peak >2 GB; acceptable on which iOS device floor?
3. **Model parity** — native SD/SDXL vs. the current FLUX/Z-Image quality; is that acceptable for v1, with
   FLUX-class staying dev-only?
4. **Scope of first §3 RC** — recommend starting with the quick native wins (segment + upscale + Core Image
   edit) which need no model hosting, then image.generate/understand.
5. **Core ML vs MLX-Swift for generation** — pick one as primary (recommend Core ML for footprint; MLX-Swift
   for model flexibility).

## 8. Next step

**Stop for approval.** On a decision (Option D + the sequencing/packaging above, or an alternative), the
first §3 RC would implement the quick native wins as an opt-in product with tests, then image
generation/understanding — with no consumer-facing Python at any point.

Sources: [apple/ml-stable-diffusion](https://github.com/apple/ml-stable-diffusion) ·
[Apple ML Research: Stable Diffusion with Core ML](https://machinelearning.apple.com/research/stable-diffusion-coreml-apple-silicon) ·
[ml-explore/mlx-swift-examples](https://github.com/ml-explore/mlx-swift-examples) (MLXVLM, StableDiffusion).
