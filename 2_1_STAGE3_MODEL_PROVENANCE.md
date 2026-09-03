# esh 2.1 UCMR — Stage 3 model/runtime research & provenance

Per Stage 3 item 12. Discovery used to find candidates; not treated as authority. Each selected
runtime/model records source, license, maintenance, Apple-Silicon support, tested revision, size,
memory, quality caveats, and known incompatibilities.

## Image generation — SELECTED: mflux (Z-Image Turbo, 4-bit)
- **Runtime**: [mflux](https://github.com/filipstrand/mflux) `0.19.1` (installed & tested). MLX-native,
  actively maintained, broad model coverage (FLUX, Z-Image, Qwen-Image, SeedVR2, …), clean CLI + Python.
- **Model**: `filipstrand/Z-Image-Turbo-mflux-4bit` (pre-quantized 4-bit of Tongyi-MAI/Z-Image-Turbo,
  6B-param single-stream DiT). ~5.5 GB on disk. **License**: Z-Image is Apache-2.0.
- **Apple Silicon**: native (MLX/Metal). Offline after download.
- **Tested**: revision `b3a8f31…`; **LIVE**: text→image via `/v1/execute` → 1024×1024 typed PNG on
  **Apple M1 Pro / 32 GB**, cold (load+generate) ~457 s. **Caveat**: that time reflects a
  memory-pressured 32 GB machine (heavy compression/swap during the run); Z-Image Turbo is designed for
  ~8-step fast generation and is far quicker with free RAM. Warm/seconds-per-image to be measured on an
  unloaded machine.
- **Rejected alternatives**: full-precision `Tongyi-MAI/Z-Image-Turbo` (~12 GB, higher peak — worse fit
  for 32 GB); FLUX.1-schnell (~12 GB bf16, heavier); packaging multiple diffusion models into the release
  (violates Stage 3 item 11 — kept on-demand instead).

## Image upscaling / enhancement — SELECTED: mflux SeedVR2
- **Runtime**: same mflux `0.19.1` (`mflux-upscale-seedvr2`). No new dependency.
- **Model**: `seedvr2-3b` (diffusion super-resolution). VAE tiling enabled to bound peak memory.
- **Capability**: `image.upscale` (a SEPARATE typed capability, not a vague `image.edit`).
- **Status**: implemented + unit-tested + RAM-guarded; live super-resolution run pending (model download
  + a memory-heavy run like image-gen). Chosen over Real-ESRGAN (no maintained MLX-native package;
  onnx/torch paths heavier) because it reuses the already-present mflux runtime.

## Video understanding — SELECTED: native AVFoundation pipeline (no new model)
- **Runtime**: Apple **AVFoundation + ImageIO** for metadata, adaptive keyframe extraction, and audio→
  16 kHz mono WAV. **No ffmpeg / no external binary** → packaging-clean, offline, clean-machine installable.
- **Composition**: keyframes → VLM (mlx-vlm, existing) + audio → STT (parakeet, existing) → LLM fusion.
  Exposed as a canonical N-step `ExecutionPlan`.
- **Honest scope**: sampled-frame + audio fusion, NOT deep temporal modeling (stated in the result/plan).
- **Status**: pipeline + plan + all branches unit-verified (short/speech, no-audio, corrupt, cancellation,
  sampler). Live end-to-end on a real clip pending a bundled test video.
- **Rejected**: brute-forcing every frame into a VLM (cost); local video *generation* (Stage 3 item 13 —
  deferred).

## Audio intelligence — SELECTED: sherpa-onnx diarization (torch-free)
- **Runtime**: [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) on **onnxruntime** (already present for
  rembg). **License**: Apache-2.0. Models: pyannote-style segmentation (~6 MB) + speaker embedding (~28 MB).
- **Capability**: `audio.diarize` → anonymous speaker CLUSTERS + time ranges (+ optional STT transcript).
- **Honest scope**: clusters, NOT speaker identity; not word-aligned to the transcript.
- **Status**: implemented + unit-tested; sherpa-onnx + models are an OPTIONAL dependency (clear error when
  absent); live run pending model download.
- **Rejected**: **pyannote.audio** — requires PyTorch (heavy; against esh's torch-free MLX/onnx preference).

## Resource / packaging notes (items 10, 11)
- All large model downloads route to the **assets root** (`/Volumes/Sviat SSD/esh-models`) via
  `HF_HOME`/`HF_HUB_CACHE`; providers call `ensureAssetsAvailable` so a disconnected SSD fails clearly
  instead of silently filling internal disk. Verified: the 5.5 GB image model landed on the SSD.
- Heavy Python deps (mflux, rembg/onnxruntime, sherpa-onnx) are **optional/on-demand**, not baked into the
  release. `Tools/python-requirements.txt` documents them.
- Temp frames/audio/video extracts are cleaned via `defer` per execution.
- RAM guard: image gen/upscale refuse/kill under genuinely low memory (below floor, or critical pressure
  AND < 2× floor) rather than thrash/crash.
