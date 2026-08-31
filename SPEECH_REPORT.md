# M10 — Local Speech Stack Report

Symmetric on-device audio in esh: text-to-speech (existing) and **speech-to-text (new — the roadmap's
stated gap: "STT is a stub").** Both run locally on Apple Silicon via MLX; no cloud.

## STT — implemented + verified

`esh audio transcribe <audio-file> [--model <id>] [--language <name>] [--json]` transcribes audio via
`mlx_audio` through the MLX bridge (`mlx-transcribe`), symmetric with the MLX TTS path. Default model:
`mlx-community/parakeet-tdt-0.6b-v2` (on-device, fetched/cached by mlx_audio).

**Verified end-to-end:** `esh audio transcribe hello.wav` → **"Hello from Esh."** (accurate).

Audio → STT → LLM pipeline verified: transcribe `hello.wav` → feed the text to `esh infer` → model
responds. The full audio → STT → LLM → **TTS** loop is blocked only by the TTS finding below.

Notes: `mlx-community/whisper-tiny` is **not** compatible (missing HF processor: `mlx_audio` raises
"Processor not found"); parakeet works. The command surfaces that honestly per model.

## TTS — fixed default + closed audio loop

TTS now works out of the box: `esh audio speak "…"` (no `--model`) produced a valid WAV. The **full
audio → STT → LLM → TTS loop is demonstrated**: `hello.wav` → STT "Hello from Esh." → LLM
"Hello from me." → TTS (143 KB WAV).

The fix: the historical default TTS model (**Marvis**) fails to load on this `TTSMLX` version (see
below), so the default now prefers a **known-working** model (`Soprano-80M`, verified). Marvis remains
selectable but is a model-specific known issue.

### Marvis — model-specific known issue

The **Marvis** TTS model still fails to load with

```
Key model.decoder.layers.0.self_attn.rope.cosF32 not found in
MarvisTTSModel.CSMModel.CSMLlamaModel.CSMTransformerBlock.CSMLlamaAttention.CSMLlama3ScaledRoPE
```

— a **weight-key / version mismatch** between the cached Marvis model and the Swift `TTSMLX`
implementation's expected RoPE keys (analogous to the qwen3.5-9b ⇄ mlx-lm mismatch the Benchmark Lab
found). This is a deep `TTSMLX`/model-version issue; fixing it blind would risk destabilizing the audio
stack, so it is **recorded as a tracked finding**, not force-patched mid-session.

## Remaining

- **Fix the Marvis RoPE-key mismatch** (pin a compatible model revision or update the `TTSMLX` key
  mapping) and re-verify `esh audio speak`; then demonstrate the closed audio → STT → LLM → TTS loop.
- TTS hardening items from the roadmap once TTS loads again: streaming/chunking + first-audio latency,
  long-text handling, cancellation, voice/language discovery polish, warm residency, and Benchmark-Lab
  integration for audio models.
- STT: streaming transcription and language auto-detection; add STT to the Web Chat and the audio
  pipeline demo once TTS is restored.
