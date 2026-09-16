# esh External-Storage Validation (feature-complete milestone)

External model storage is a core esh use case: large local-AI assets live on a configured storage volume
(here `/Volumes/Sviat SSD/esh-models`, exFAT, ~685 GiB free) while the internal disk holds only lightweight
state and build metadata. This documents the configurable-storage fix and the on-device validation sweep.

## Configured storage root

`~/.esh/storage.json` sets `assetsRoot = /Volumes/Sviat SSD/esh-models` with a matching `assetsVolumeID`
(the `.esh-storage.json` marker on the volume). `PersistenceRoot.default()` resolves this, so
`caches/`, `models/`, `audio/`, `artifacts/`, and `tmp/` all live on the SSD.

## What was routed off the internal disk (the fix)

Before this milestone, new native + third-party paths defaulted heavy I/O to the internal disk. Fixed:

| Consumer | Was (internal) | Now (assets volume) |
|---|---|---|
| Native VLM (EshVision, MLX-Swift) | `~/Documents/huggingface` | `caches/hf-swift` via `HubApi(downloadBase:)` |
| Native image-gen (EshImageGen, MLX-Swift SD) | `~/Documents/huggingface` | `caches/hf-swift` via `HubApi(downloadBase:)` |
| Compat HF weights (music/SFX/edit) | `~/.cache/huggingface` | `caches/{audio,image}-models` via per-request `hfCache` + `HF_HOME`/`HF_HUB_CACHE` env |
| Diarization models (sherpa-onnx) | (n/a) | `audio/diarization-models` (paths passed to the bridge) |
| Compat temp/staging | `/tmp` | `tmp/` (`TMPDIR` env + `context.root.tempURL`) |
| Compat runtime venv + pip cache | `~/…`, `~/Library/Caches/pip` | `runtime/py311/venv`, `tmp/pip-cache` (`PIP_CACHE_DIR`) |
| AudioGen SFX isolated venv | `~/…` | `esh-runtime/audio/audiogen-mlx/venv` (bridge known path) |

Kept on the internal disk by design: Xcode/SwiftPM **build metadata** (DerivedData) — not a model/runtime asset.

## Assets reused vs downloaded (no duplicate multi-GB downloads)

Reused verified assets already on the SSD (matched by repo id / format; integrity by the runtime's own load):
- `facebook/musicgen-small` (music) — `caches/audio-models/hub`
- `facebook/audiogen-medium` (SFX) — `caches/audio-models/hub`
- `filipstrand/Z-Image-Turbo-mflux-4bit` (image.generate, Apache-2.0) — `caches/image-models/hub`, 5.5 GB
- `mflux-community/qwen-image-edit-2511-mflux-q4` (image.edit, Apache-2.0) — `caches/image-models/hub`, 27 GB
- sherpa-onnx `segmentation.onnx` + `embedding.onnx` (diarization) — `audio/diarization-models`, 44 MB

Fresh downloads (to the SSD, not internal):
- `mlx-community/Qwen2-VL-2B-Instruct-4bit` (native VLM) — `caches/hf-swift`, ~1.2 GB (not previously present)
- SD 2.1 base from the public mirror `Manojb/stable-diffusion-2-1-base` — iOS-native workstream (checksum-pinned)

## Real end-to-end validation (public EshRuntime facade, assets on the SSD)

Each: discovery state, typed artifact **written to the SSD artifacts dir**, cancellation (no orphan),
reuse, and relaunch (freshly recreated runtime).

| Capability | Provider | Result |
|---|---|---|
| image.understand (VLM) | native MLX-Swift (Qwen2-VL) | model downloaded to SSD `caches/hf-swift`; internal `~/Documents/huggingface` stayed 0 B; real inference + cancel + reuse |
| audio.diarize | compat sherpa-onnx | ALL CHECKS PASSED — JSON artifact on SSD |
| music.generate | compat MusicGen | ALL CHECKS PASSED — 252 KB WAV on SSD (reused musicgen-small) |
| image.generate (macOS) | compat mflux Z-Image-Turbo | ALL CHECKS PASSED — 324 KB PNG on SSD (reused Z-Image-Turbo; Apache-2.0) |
| image.edit | compat mflux qwen-image-edit | Experimental — wired + discoverable; end-to-end real-validation still in progress |
| audio.generate (SFX) | compat mlx-audiocraft AudioGen | Experimental — resource-gated on this device's current state (swap headroom); reported honestly as insufficient-resources, not a defect. See SDK_CAPABILITY_MATRIX.md "SFX resource classification" |

## External-storage robustness

- **Storage-unavailable / unplug:** `StorageService.availability(root:)` reports `unavailable` cleanly when
  the volume is missing / marker-mismatched / not writable; internal-only roots return `.internalRoot`
  (no false failures). Heavy paths gate on it: the compat host fails with "model storage is unavailable: …"
  and the native MLX providers do the same on first load (in-process reuse from RAM is not blocked). Unit
  test: `storageUnavailableFailsCleanly`.
- **exFAT AppleDouble gotcha:** macOS writes `._*` sidecars on exFAT; Python package scans (transformers)
  choke on them. The audio-runtime setup strips them post-install; the same is needed for any esh-managed
  venv on exFAT. (Finding captured; see `scripts/setup-audio-runtime.sh`.)

## Disk usage

(SSD used by esh-models and internal free — filled in at sweep completion.)
