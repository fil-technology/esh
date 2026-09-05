# esh 2.1 — Generative Audio Runtime (audio.generate + music.generate)

**Status (2026-09-05, production closure):** two Universal Capability Runtime capabilities, distinct from
speech/diarize/understand. The SFX listening gate **passed**, so neural `audio.generate` (AudioGen) is now
**production-ready**. A *genuine* SFX model backs it in an **isolated runtime**, MusicGen is confined to
`music.generate`, cancellation is orphan-free, outputs are clip-safe, weights are SSD-only, and `doctor`
reports audio state. MusicGen remains **experimental** (CC-BY-NC + limited quality evaluation).

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
- `CapabilityRequirementCatalog`: `audio.generate` → `audiogen-medium` (~3600 MB), `music.generate` → `musicgen-small` (~2200 MB).
- Deterministic waveforms are **exempt** from the install requirement (they need no model).
- `esh doctor` reports: SFX runtime discoverable? SFX/music model cached? — with licenses, in human + `--json`.

**Live-verified (isolated test root):** with the model absent, `POST /v1/route` for an SFX prompt returned
`installRequired` carrying the `InstallRequirement` (component "AudioGen (SFX, isolated runtime)", repo
`facebook/audiogen-medium`, 3600 MB) + Model Fit ("comfortable", peak ~6.9 GB) + a `pendingId`. After the
model was installed to the managed SSD volume, the same request routed `ready` and `POST /v1/execute` produced
a valid AudioArtifact — the original prompt resumed end-to-end.

**Model Fit — predicted vs measured (on-disk):**
| Model | Catalog estimate | Measured on SSD | Note |
|---|---|---|---|
| AudioGen-medium | ~3600 MB | **3.6 GB** | matches |
| MusicGen-small | ~2200 MB (corrected from 1200) | **2.2 GB** | **catalog updated to measured** — cache includes T5 encoder + EnCodec + fp32 |

Three dimensions are reported **separately** (never conflated): **weights/storage** (the catalog `approxSizeMB`,
matched to on-disk), **peak runtime memory** (the bridge free-RAM floors: SFX 6000 MB, music 2500 MB; Model Fit
estimates ~6.9 GB peak for AudioGen → "comfortable" on 32 GB), and **performance** (generation RTF: SFX
~5.6–6.3×, music ~1.4–1.9×). Both backends refuse to start on low memory (clear error) rather than thrash.

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

All 7 non-silent, structurally valid, 16 kHz mono (AudioGen native). Peaks are stochastic (`do_sample`); a
re-run saw two fixtures exceed 1.0 (footsteps 1.03, night-forest 1.06) and the **same limiter** normalized
them clip-free — SFX gets the identical clip-safety guarantee as music.

## Frozen benchmark — music (MusicGen-small, cold load 9.2 s)
| Fixture | Prompt | Dur | Gen | RTF | kHz | Peak | Valid |
|---|---|---|---|---|---|---|---|
| A_ambient_synth | warm ambient synth pad, no drums | 11.94 s | 23.0 s | 1.93× | 32 | 0.395 | ✓ |
| B_cinematic | cinematic orchestral cue building tension | 11.94 s | 17.2 s | 1.44× | 32 | 0.125 | ✓ |
| C_lofi | instrumental lo-fi hip-hop study loop | 11.94 s | 17.1 s | 1.43× | 32 | **1.462 ⚠ clipping** | ✓ (struct) |
| D_piano | melancholic solo piano with a motif | 11.94 s | 16.9 s | 1.42× | 32 | 0.352 | ✓ |
| E_retro_game | retro chiptune game soundtrack loop | 11.94 s | 17.2 s | 1.44× | 32 | 0.697 | ✓ |

All valid. **Clipping fixed:** a deterministic true-peak limiter (ceiling 0.99, linear gain → dynamics
preserved, no-op when safe) now caps any output that would clip. On a re-run C_lofi generated peak ~1.09 →
**normalized (clip-free)**; safe fixtures untouched. `peak` (pre-limiter) + `normalized` are in provenance;
regression covered by `Tests/Python/test_mlx_vlm_bridge.py` (limiter caps clipping, preserves ratios, leaves
safe/silent output alone). Peaks vary per run (`do_sample`), so the limiter — not any single fixture — is the guarantee.

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
- **SFX listening gate PASSED** — neural `audio.generate` is production. Music quality is still evaluated
  only lightly, and MusicGen is **CC-BY-NC** (non-commercial), so `music.generate` stays experimental.
- Cold-load dominates latency (on-demand, no warm pool). Acceptable, documented, revisitable if usage grows.
- Model Fit reuses the image fit model, so its working-memory reason mentions "1024x1024" — cosmetic; the
  memory numbers and fit class are conservative and correct. An audio-specific fit descriptor is a minor follow-up.

## Verdicts
- **`AUDIO.GENERATE`: PRODUCTION-READY.** Deterministic DSP (exact noise/tones/sweeps) **and** neural SFX
  (AudioGen, isolated runtime) are both production: real SFX model, listening gate passed, canonical
  Install-and-Resume (live-verified), Model Fit, clip-safe output, orphan-free cancellation, offline, SSD-only,
  licenses surfaced honestly, through `/v1/execute` with a Web player.
- **`MUSIC.GENERATE`: EXPERIMENTAL.** End-to-end, SSD-only, cancellable, clip-safe, licensed (CC-BY-NC);
  held experimental by the non-commercial license and limited quality evaluation — **not** a blocker on
  shipping `audio.generate`.

## Scheduler (final dispatch)
```
white/pink/brown noise → deterministic DSP     tone/sweep/silence → deterministic DSP
environmental sound / Foley / ambience → AudioGen (neural SFX)     music → MusicGen
```
No hard-coded permanent model IDs in provider logic; MusicGen is never an environmental-SFX fallback.

## Next (do not auto-start)
Optional future work only: an audio-specific Model Fit descriptor, and a warm pool if audio becomes
high-frequency. Do **not** start audio.edit / music remix / Voice 2.1 / video in this milestone.
