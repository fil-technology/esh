# esh 2.1 UCMR — Stage 3 model/runtime research, provenance & LIVE validation

Per Stage 3 items 12 + final validation pass. Discovery used to find candidates; not authority. All
timings measured on **Apple M1 Pro / 32 GB**, assets on external SSD `/Volumes/Sviat SSD/esh-models`.

## Image generation — mflux Z-Image-Turbo 4-bit — LIVE ✅ (but compute-slow)
- **Runtime**: mflux `0.19.1` (MLX-native, maintained). **Model**: `filipstrand/Z-Image-Turbo-mflux-4bit`
  (rev `b3a8f31…`, pre-quantized 4-bit of Tongyi-MAI/Z-Image-Turbo, 6B DiT), ~5.5 GB. **License**: Apache-2.0.
- **LIVE**: text→image via `/v1/execute` → valid 1024×1024 typed PNG. Verified end-to-end.
- **Benchmarks** (recorded, `~/.esh/benchmarks/image-generation-benchmarks.json`):
  - 1024×1024, 8 steps: **~215 s warm** (216.3 / 213.3 s; ~25 s/step), cold 457 s (first-run Metal
    compile + memory pressure). Peak RSS **4.4 GB**.
  - 512×512, 8 steps: **51 s** (~5.6 s/step). Peak RSS **4.4 GB** (same).
  - **Root-cause of the 457 s**: not memory — fetch was a cache hit (~0 s), peak 4.4 GB, no swap; it is
    **GPU-compute-bound** (~25 s/step at 1024²). Resolution is the dominant lever (~4× from 1024²→512²).
  - **Recommendation note**: 1024² at ~215 s is **not interactive-grade** on M1 Pro; 512² (~51 s) is
    borderline. Correct + fits comfortably in memory, but a 6B model is slow here. Samples are marked
    recommendation-grade (measured under normal pressure); Scheduler/Auto should weigh seconds/image, and
    consider a lighter default (e.g. an SD-Turbo class model) or default to 512² on this machine class.
- **Rejected**: full-precision Z-Image (~12 GB); FLUX.1-schnell (~12 GB, heavier); baking models into the
  release (kept on-demand).

## Image upscaling — Real-ESRGAN ONNX — LIVE ✅ (Stage 4.1; SeedVR2 kept experimental)
- **DEFAULT runtime**: **Real-ESRGAN ONNX on onnxruntime** (CoreML execution provider + CPU fallback),
  torch-free. **Model**: `SceneWorks/real-esrgan-onnx` — dynamic-shape RRDBNet, **x2 + x4**, 64 MB each.
  **License**: BSD-3-Clause (Real-ESRGAN). Auto-downloaded on demand to the assets root
  (`caches/upscale-models/`). **Capability**: `image.upscale` (separate typed capability).
- **Candidate evaluation**: chose SceneWorks (dynamic shape → no tiling needed) over AXERA-TECH
  (fixed 64×64 input → needs tiling) and qualcomm (gated repo). MLX-native ports exist
  (themindstudio / mlx-community) but the ONNX path reuses already-present onnxruntime with a clean
  provider boundary and CoreML acceleration.
- **LIVE** via `/v1/execute image.upscale` on M1 Pro / 32 GB:
  - 2×: 512→1024, cold 7.8 s / warm 7.4 s.
  - 4×: 512→2048, ~12 s, **peak RSS 10.7 GB** (activation maps scale with output pixels — large inputs
    would need tiling; a Stage 4 refinement), output 4.7 MB, CoreML EP.
  - Typed artifact metadata `{width,height,scale}` correct; ExecutionPlan present; model on SSD (internal
    disk untouched); no leftover processes/temp files; RAM pre-check + graceful errors validated.
- **Quality**: clean photo-like super-resolution on the test image; no severe artifacts.
- **EXPERIMENTAL fallback** `seedvr2` (mflux): still fails upstream on mflux 0.19.1 + mlx 0.32.2
  (`mx.repeat` array repeats). Kept selectable via `options.backend=seedvr2` for future retest, **never
  the default**. (Storage routing / RAM guard / graceful error were validated on it too.)
- **Rejected**: pyannote-style torch upscalers (torch); baking upscale models into the release (on-demand).

## Video understanding — native AVFoundation pipeline — LIVE ✅
- **Runtime**: Apple **AVFoundation + ImageIO** (metadata, adaptive keyframes, audio→16 kHz WAV). **No
  ffmpeg** in esh — packaging-clean, offline. Composition: keyframes → VLM (nanoLLaVA) + audio → STT
  (parakeet) → LLM fusion (llama-3.2-3b). Canonical N-step `ExecutionPlan`.
- **LIVE** (synthetic clip: red circle→blue square visuals + "meeting Thursday 3 o'clock" speech,
  deliberately disjoint so each branch is provable):
  - visual-only Q → "Red circle (0:00), Blue square (0:02); red, white, blue" ✅ (VLM, with timestamps)
  - audio-only Q → "Thursday afternoon, 3 o'clock" ✅ (STT)
  - combined Q → fuses both with timestamps ✅
  - ~13–25 s/question. Plan verified: metadata→keyframes→image-understand×2→audio-extract→STT→language-fuse.
- **Honest scope**: sampled-frame + audio fusion, NOT deep temporal modeling (stated in plan rationale).
- **Known gap**: esh mis-classifies nanoLLaVA as text-only at install, so Auto can't resolve a VLM yet —
  the request passes `options.visionModel` explicitly. VLM auto-classification is a Stage 4 item.
- **Rejected**: brute-forcing every frame; local video generation (item 13, deferred).

## Audio diarization — sherpa-onnx — LIVE ✅
- **Runtime**: sherpa-onnx (onnxruntime, torch-free). **Models** (on SSD `audio/diarization-models/`):
  pyannote segmentation `model.int8.onnx` (5.7 MB) + 3D-Speaker ERes2Net embedding (38 MB). Apache-2.0.
- **LIVE** (2-speaker synthetic audio, two TTS voices concatenated, 9 s): correctly found **2 speakers**,
  3 segments with timestamps (speaker_1 ≈ 0–4.1 s, speaker_2 ≈ 4.1–9 s), structured JSON typed result,
  **STT transcript merged** (parakeet), honest "clusters, not identities" note. ~9 s latency.
- **Capability**: `audio.diarize` (audio→structured). sherpa-onnx + models optional (clear error absent).
- **Rejected**: pyannote.audio (requires PyTorch — against the torch-free preference).

## Resource / packaging (items 10, 11) — validated
- Large model downloads route to the **assets root (SSD)** via `HF_HOME`/`HF_HUB_CACHE`; verified: Z-Image
  (5.5 GB) and SeedVR2 (6.8 GB) landed on the SSD, internal disk stayed ~15–34 GB free. Providers call
  `ensureAssetsAvailable` → a disconnected SSD fails clearly.
- Heavy Python deps optional/on-demand: mflux (image), rembg/onnxruntime (segment), sherpa-onnx (diarize).
  Documented in `Tools/python-requirements.txt`. No developer-machine-only deps in esh's runtime path
  (ffmpeg is used ONLY to build test fixtures, never by esh).
- Temp frames/audio/video cleaned per run (`defer`). RAM guard refuses/kills generation only when memory
  is genuinely low (below floor, or critical pressure AND < 2× floor) — refined after a false-positive kill.

## Model Fit reconciliation (item 6)
- Predicted image peak (heuristic, weightsGB=disk 6.5) ~9.9 GB vs **observed 4.4 GB** → memory model is
  **conservative/safe** (no OOM, no swap; "Comfortable" is memory-correct).
- Gap: Fit expresses MEMORY only; a memory-Comfortable model can still be slow (215 s). Image Fit now
  carries an explicit caveat ("memory fit only — speed is compute-bound and scales with resolution"). True
  performance-aware selection (benchmark seconds/image) is a Scheduler v2 / Auto task (Stage 4). Global Fit
  semantics unchanged.
