# esh 2.1 — Generative Audio Runtime (audio.generate + music.generate)

**Status (2026-09-05, closure pass):** two Universal Capability Runtime capabilities, distinct from
speech/diarize/understand. This revision closes the production gaps from the initial build: a *genuine* SFX
model (AudioGen) now backs neural `audio.generate` in an **isolated runtime**, MusicGen is confined to
`music.generate`, cancellation is orphan-free, model weights are SSD-only, and `doctor` reports audio state.

## Capability taxonomy
- **`audio.generate`** — non-speech environmental sound, ambience, SFX, Foley.
- **`music.generate`** — musical compositions, loops, scores, instrumental output.

One `audio.generate` capability, **two provider paths chosen by a classifier** (esh schedules *capabilities*):
- **Deterministic DSP** — white/pink/brown noise, tones, sweeps, silence. Exact, instant (<0.2 s), reproducible per seed, no model, no install.
- **Neural text→audio (AudioGen)** — environmental sound the DSP can't synthesize (rain, footsteps, waves, fireplace).

Scheduler policy (no hard-coded permanent model IDs in provider logic):
white noise / tone → **deterministic DSP**; forest rain / footsteps / ambience → **AudioGen** (SFX);
ambient synth / music → **MusicGen**.

## SFX candidate comparison (Apple-Silicon, this machine, 2026 landscape)
| Model | Runtime | Domain | License | Decision |
|---|---|---|---|---|
| **AudioGen-medium** (facebook) | mlx-audiocraft (MLX-native), isolated venv | SFX / environmental | CC-BY-NC-4.0 | **SELECTED** — MLX-native, isolated deps, qualified live |
| Stable Audio Open Small | stable-audio-tools (torch) | SFX + music | Stability Community (gated) | rejected for now — HF-gated, torch stack conflicts with shared venv |
| AudioLDM 2 | diffusers (torch) | SFX + music | CC-BY-NC-SA-4.0 | rejected — heavier license (SA), torch/diffusers weight in shared venv |
| MusicGen-small (steered) | transformers/MPS | music (SFX only by steering) | CC-BY-NC-4.0 | **rejected as SFX backend** — a music model is not an SFX model |

**Why AudioGen wins here:** it is the only qualified candidate that runs MLX-native (`mlx-audiocraft`) and can
be installed in an **isolated venv** on managed storage, so its pinned deps never destabilize the shared
MLX LLM/VLM runtime. Only 1 candidate was pulled for live eval (no blind multi-GB downloads).

## Isolated runtime (why + how)
`mlx-audiocraft` pins deps that must not touch the main esh venv. It lives in a dedicated venv on the SSD:
- Provisioned by `scripts/setup-audio-runtime.sh` (pinned `python3.11` + `mlx-audiocraft==0.1.0`, reproducible, re-runnable).
- Default `RUNTIME_DIR=/Volumes/Sviat SSD/esh-runtime/audio/audiogen-mlx`; discovered by the bridge via
  `ESH_AUDIOGEN_PYTHON` or known managed paths (`…/esh-runtime/audio/…` or `~/.esh/runtime/audio/…`).
- The SFX worker (`Tools/esh_audiogen.py`) runs **inside** that venv; the bridge (`mlx_vlm_bridge.py`) shells
  out to it. Clean removal = delete the venv dir; zero impact on the LLM/VLM runtime.
- exFAT SSDs create AppleDouble `._*` sidecars that break transformers' module scan — the setup script strips
  them and the runtime forces `PYTHONUTF8=1` / `COPYFILE_DISABLE=1`.

## Install-and-Resume + Model Fit
Neural audio is first-class in the canonical flow (request → Router → capability → provider missing →
InstallRequirement → user approves → install to SSD → verify → resume). No hidden multi-GB fetch.
- `CapabilityRequirementCatalog`: `audio.generate` → `audiogen-medium` (~3600 MB), `music.generate` → `musicgen-small` (~1200 MB).
- Deterministic waveforms are **exempt** from the install requirement (they need no model).
- `esh doctor` reports: SFX runtime discoverable? SFX/music model cached? — with licenses, in human + `--json`.

**Model Fit — predicted vs measured (on-disk):**
| Model | Catalog estimate | Measured on SSD | Note |
|---|---|---|---|
| AudioGen-medium | ~3600 MB | **3.6 GB** | matches |
| MusicGen-small | ~1200 MB | **2.2 GB** | estimate low — cache includes T5 encoder + EnCodec + fp32; catalog figure should be raised |

Memory-fit is reported separately from speed: SFX enforces a **6000 MB** free-RAM floor before launch,
music a 2500 MB floor. Both refuse to start (clear error) rather than thrash near the ceiling.

## Frozen benchmark — SFX (AudioGen-medium, isolated runtime, cold load 12.7 s)
| Fixture | Prompt | Dur | Gen | RTF (gen) | kHz | Peak | Valid |
|---|---|---|---|---|---|---|---|
| A_forest_rain | gentle rain in a dense forest, distant birds | 8 s | 44.5 s | 5.57× | 16 | 0.132 | ✓ |
| B_shore_waves | waves on a rocky shore, coastal wind | 8 s | 49.9 s | 6.24× | 16 | 0.554 | ✓ |
| C_fireplace | close fireplace crackling in a quiet room | 8 s | 50.6 s | 6.33× | 16 | 0.139 | ✓ |
| D_cafe | busy café ambience, no intelligible speech | 8 s | 49.1 s | 6.13× | 16 | 0.107 | ✓ |
| E_footsteps | footsteps on wet pavement at night | 8 s | 44.4 s | 5.55× | 16 | 0.826 | ✓ |
| F_thunder_rain | distant thunder and rain | 8 s | 49.3 s | 6.16× | 16 | 0.155 | ✓ |
| G_night_forest | calm nighttime forest, loopable | 8 s | 49.9 s | 6.24× | 16 | 0.093 | ✓ |

All 7 non-silent, structurally valid, no clipping (peaks ≤ 0.83). 16 kHz mono (AudioGen native).

## Frozen benchmark — music (MusicGen-small, cold load 9.2 s)
| Fixture | Prompt | Dur | Gen | RTF | kHz | Peak | Valid |
|---|---|---|---|---|---|---|---|
| A_ambient_synth | warm ambient synth pad, no drums | 11.94 s | 23.0 s | 1.93× | 32 | 0.395 | ✓ |
| B_cinematic | cinematic orchestral cue building tension | 11.94 s | 17.2 s | 1.44× | 32 | 0.125 | ✓ |
| C_lofi | instrumental lo-fi hip-hop study loop | 11.94 s | 17.1 s | 1.43× | 32 | **1.462 ⚠ clipping** | ✓ (struct) |
| D_piano | melancholic solo piano with a motif | 11.94 s | 16.9 s | 1.42× | 32 | 0.352 | ✓ |
| E_retro_game | retro chiptune game soundtrack loop | 11.94 s | 17.2 s | 1.44× | 32 | 0.697 | ✓ |

Structurally valid; **C_lofi clips (peak 1.462 > 1.0)** — a real quality defect (needs peak normalization/limiter before production).

## Lifecycle (measured) — on-demand, no warm pool
Both neural families spawn a **fresh process per call** (SFX = isolated worker; music = bridge), load the
model, generate, and exit. Repeat calls show **no residency speedup** (SFX ~39 s both times for 4 s), so
cold model-load dominates wall time (wall RTF ~9.8× for a 4 s SFX clip vs ~5.6–6.3× generation-only). No
memory is held while idle; there is nothing to evict. **Decision: keep on-demand** for now — a warm/resident
worker was deliberately *not* built (it would hold multi-GB resident for a low-frequency capability). Revisit
a warm pool only if audio generation becomes high-frequency.

## Cancellation & recovery (live-verified)
- **Client disconnect during generation → producer cancelled in ~2 s, worker reaped, no orphan.** Verified for
  both SFX (isolated worker) and music (in-bridge) via the streaming endpoint.
- Two real bugs found and fixed in this pass:
  1. **Streaming never detected client disconnect** — a long generation ran to completion on a dead socket.
     Fixed: a pending receive on the connection now signals hang-up and cancels the producer.
  2. **Isolated worker orphaned on cancel** — `start_new_session` means parent death does *not* reclaim it.
     Fixed: the bridge registers worker process-groups and a SIGTERM reaper SIGKILLs them before exit.
- On cancel the provider throws before saving → **no corrupt "success" artifact**. Server stays healthy and
  the next request (deterministic gen) succeeds in <0.1 s.

## Offline / storage isolation (verified)
- After install, SFX generates **fully offline** (`HF_HUB_OFFLINE=1`) from the SSD cache — no hidden fetch.
- Weights are SSD-only. Fixed a **~2.2 GB MusicGen leak onto the internal disk**: `huggingface_hub` freezes
  its cache dir at import (before the env route ran), so `from_pretrained` now passes `cache_dir` explicitly.
  Re-verified: a fresh music run recreates **no** internal copy.

## Licensing (exposed honestly, never hidden)
- **AudioGen-medium: CC-BY-NC-4.0** (non-commercial). **MusicGen-small: CC-BY-NC-4.0** (non-commercial).
- Deterministic DSP: **no model, no license encumbrance**.
- License is carried in every artifact's provenance/metadata, rendered in the Web player, and shown by `doctor`.
  esh is open-source; the NC models are opt-in and labelled, not silently baked into a "production" claim.

## What is built + verified
- Capability IDs + typed `.audio` AudioArtifact (WAV) with duration/sampleRate/channels/prompt/seed/provider/model/license; WAV validator (RIFF, frames, duration match, silence flag). Duration never silently shortened.
- Router (Tier-0): all 7 frozen SFX + 5 music fixtures route correctly (unit-tested); visual/web precedence; `no music` negation; weak-audio nouns gated on framing.
- Providers through canonical `POST /v1/execute`; Web `<audio>` player labelled `provider · duration · kHz`.
- Full suite **550 green** (incl. audio routing/validation + new doctor audio test).

## Honest limitations
- **SFX + music quality are pending a human listening gate.** Structural validity, routing, RTF, RAM, and
  clipping are machine-verified; whether "rain" *sounds* like rain, and whether music is coherent, is an
  ear judgment. Bundles (7 SFX + 5 music) delivered to the operator; **neural SFX is not marked production
  until that gate passes.**
- MusicGen **C_lofi clips** — needs a limiter/normalizer before any production music claim.
- Cold-load dominates latency (on-demand). Acceptable, documented, revisitable.

## Verdicts
- **`AUDIO.GENERATE`: PARTIAL.** Deterministic DSP path is **PRODUCTION-READY** (exact, instant, validated,
  through `/v1/execute`, Web player). Neural SFX (AudioGen, isolated runtime) is **EXPERIMENTAL** — real SFX
  model, canonical install, Model Fit, orphan-free cancel, offline, SSD-only, licensed honestly — **pending
  the human listening gate** to flip to production.
- **`MUSIC.GENERATE`: EXPERIMENTAL.** End-to-end, SSD-only, cancellable, licensed (CC-BY-NC); not
  production-gated (clipping defect + listening gate + NC license outstanding).

## Next (do not auto-start)
Await the operator's listening judgment on both bundles. Then, if approved: add peak-normalization to the
music path, raise the MusicGen catalog size estimate to ~2.2 GB, and consider a warm pool only if usage
warrants. Do **not** start audio.edit / music remix / video in this milestone.
