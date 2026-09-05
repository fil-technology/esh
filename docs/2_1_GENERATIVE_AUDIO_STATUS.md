# esh 2.1 — Generative Audio Runtime (audio.generate + music.generate)

**Status (2026-09-05):** two new Universal Capability Runtime capabilities, distinct from speech/diarize/understand.

## Capability taxonomy
- **`audio.generate`** — non-speech environmental sound, ambience, SFX, Foley.
- **`music.generate`** — musical compositions, loops, scores, instrumental output.

One `audio.generate` capability, **two provider paths chosen by a classifier** (esh schedules *capabilities*, not just models):
- **Deterministic DSP** — white/pink/brown noise, tones, sweeps, silence. Exact, instant (<0.2 s), reproducible per seed, no model.
- **Neural text→audio** — environmental sound the DSP can't synthesize (rain, footsteps, café).

## Candidate research (Apple-Silicon, this machine)
| Model | Runtime | sound/music | License | Fit / status |
|---|---|---|---|---|
| Deterministic DSP (esh) | pure Swift | sound (noise/tones) | none | **PRODUCTION** — exact, instant |
| **MusicGen-small** (facebook) | transformers / MPS | music (+ sound via steering) | CC-BY-NC-4.0 | works: 5 s in ~12 s (RTF ~2.4×), 32 kHz, ~4 GB peak |
| AudioGen-medium (facebook) | audiocraft | sound | CC-BY-NC-4.0 | audiocraft not installed; audiocraft-format weights, heavy/pinned deps — **recommended in an ISOLATED venv** |
| Stable Audio Open Small | stable-audio-tools | both | Stability Community | not installed; HF-gated — alternative SFX upgrade |

## What is built + verified
- Capability IDs `audio.generate` / `music.generate`; typed **`.audio` AudioArtifact** (WAV) with duration/sampleRate/channels/prompt/seed/provider/model/license; **WAV validator** (RIFF, frames, duration match, silence flag). Requested duration never silently shortened.
- **Router** (Tier-0): sound/ambience → audio.generate, music/synth → music.generate, with visual/web precedence and `no music` negation. **All 7 frozen sound + 5 music fixtures route correctly** (unit-tested).
- **Providers** through canonical `POST /v1/execute`: deterministic DSP + neural (RAM-guarded MusicGen bridge, weights on SSD).
- **Web player**: `.audio` artifacts render as a native `<audio>` player + Download, labelled `provider · duration · kHz`.
- **Live-verified:** white/pink noise + 440 Hz tone → valid WAV in <0.2 s (deterministic); `music.generate` ("warm ambient synth pad") + `audio.generate` ("rain in a forest, no music") → valid 7.9 s @ 32 kHz WAV via MusicGen, memory-safe (57% free). Full suite **549 green** (+6 audio tests).

## Benchmark (representative; full frozen set is generatable)
| Capability | Prompt | Provider | Actual dur | Latency | Valid | Notes |
|---|---|---|---|---|---|---|
| audio.generate | 5 s white noise | deterministic-dsp | 5.00 s | 0.17 s | ✓ | exact, 44.1 kHz, peak 0.60 |
| audio.generate | 3 s pink noise | deterministic-dsp | 3.00 s | 0.08 s | ✓ | exact |
| audio.generate | 2 s 440 Hz tone | deterministic-dsp | 2.00 s | 0.06 s | ✓ | exact |
| music.generate | warm ambient synth pad | musicgen-small | 7.94 s | ~73 s cold | ✓ | 32 kHz, CC-BY-NC |
| audio.generate | rain in a forest, no music | musicgen-audio | 7.94 s | ~26 s | ✓ | music model steered to ambience |

## Honest limitations
- **SFX fidelity is unverified by ear.** The neural audio.generate path uses MusicGen (a *music* model steered toward ambience) because AudioGen isn't installed here (audiocraft-format, heavy deps that would risk the shared MLX/mflux venv). It produces valid audio for the frozen SFX prompts, but whether "rain" *sounds* like rain vs. music is a human-eval judgment (samples sent to the operator). This is explicit in provenance (`provider: musicgen-audio`), never a silent substitution.
- **music.generate** is functional but RTF ~2.4× and CC-BY-NC; musical quality by ear not gated here.
- **Model Fit / Install-and-Resume** for the audio models are wired at the provider level (RAM floor, SSD cache, honest failure), but a first-class install card + pre-download disk/fit estimate for the neural models is a follow-up (they currently download on first neural use).

## Verdicts
- **`AUDIO.GENERATE`**: the **deterministic path is PRODUCTION-READY** (exact, real, fast, validated, Web player, through `/v1/execute`); the **neural SFX path is EXPERIMENTAL** pending a dedicated SFX model (AudioGen/Stable Audio in an isolated venv) and human quality judgment. Overall honest status: **AUDIO.GENERATE NOT READY** for arbitrary neural SFX (deterministic subset production).
- **`MUSIC.GENERATE`**: **EXPERIMENTAL** — MusicGen works end-to-end but quality/latency/license are not production-gated.

## Next recommendation (do not auto-start)
Install **AudioGen-medium (audiocraft)** or **Stable Audio Open Small** in an ISOLATED venv, add a distinct bridge backend, and re-run the frozen sound benchmark with human evaluation — this is what flips `audio.generate` neural SFX to production. Then: audio.edit, music.extend/remix, stem separation, reference-audio conditioning.
