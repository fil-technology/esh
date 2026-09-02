# esh 2.1 — Research Report

State of the Apple-Silicon local-inference ecosystem (as of Sept 2026) + local proofs, to seed the 2.1
roadmap. **Labels:** `[AVAILABLE]` confirmed in a primary repo/doc · `[EXPERIMENTAL]` present but early ·
`[CLAIMED]` asserted by secondary/blog sources only · `[UNKNOWN]` unconfirmed.

## Methodology & honesty caveat
Findings come from primary source trees (raw GitHub, HF registry API, Apple docs), not search
summaries, wherever possible. **Both web-research passes independently found that 2026 search results
are heavily polluted with AI-generated blog content carrying fabricated specifics** (invented model
names, fake Metal/M5 benchmark numbers, fake arXiv PDFs). Consequently: **every performance multiplier
is `[CLAIMED]` until esh measures it locally.** Upstream identifies *candidates*; esh benchmarks decide
defaults.

## A. Local proofs (measured on this Mac — M1 Pro / 32 GB, stable brew 2.0.0)
- **STT (parakeet):** 6.3 → 5.0 → 4.0 s across consecutive calls — barely warms. **The real
  voice-latency bottleneck.**
- **TTS (pocket-tts):** cold 1.28 s → warm ~0.5 s (mlx-audio caches weights). Modest residual overhead;
  the win is streaming/first-audio + shared lifecycle, not "reloads every call."
- **GGUF (3B Q4, bundled llama-server, Metal):** ~129 tok/s prompt, ~55 tok/s gen; warm residency
  0.24 s; strict JSON schema native; **speculative draft-model flags already present** in the bundled
  b8660 binary.
- **MLX (deepseek-r1 7B):** warm ~0.56 s; reasoning clean after the rc.7 stop-token fix.

## B. MLX ecosystem
- **mlx-lm speculative decoding** `[AVAILABLE]`: draft-model only — `--draft-model`,
  `--num-draft-tokens` (default 2); `speculative_generate_step(...)`. **Requires a *trimmable* prompt
  cache**, so it's mutually exclusive with quantized/rotating KV. **No EAGLE/Medusa/MTP in mlx-lm.**
- **mlx-vlm speculative stack** `[AVAILABLE/EXPERIMENTAL]`: richer — `--draft-kind {mtp,dflash,dspark}`,
  `mlx_vlm/speculative/` (DFlash, DSpark, MTP shared-KV drafters), plus `apc.py`, `moe_offload.py`,
  `kv_quant.py`, `turboquant.py`. This is where self-/MTP speculation lives, not mlx-lm.
- **KV cache** `[AVAILABLE]`: `--kv-bits`, `--kv-group-size`, `--quantized-kv-start` (QuantizedKVCache);
  rotating `--max-kv-size` (RotatingKVCache) — **rotating+quantized not combinable; neither is
  trimmable** (blocks spec decoding). Disk prompt caches: `mlx_lm.cache_prompt`/`--prompt-cache-file`,
  `save/load_prompt_cache` (safetensors) → persistent/reusable across processes; in-process
  `LRUPromptCache`+`PromptTrie`.
- **mlx_lm.server** `[AVAILABLE]`: OpenAI-compatible, **resident model + hot model-switching**
  (per-request `model`/`adapters`/`draft_model`), server prefix-cache reuse. **Gap:** no server-side
  `--kv-bits` (KV-quant is generate-only); docs say "not recommended for production."
- **mlx-audio** `[AVAILABLE model-level; server-level UNKNOWN]`: `mlx_audio.server` exposes
  `/v1/audio/speech` + `/v1/audio/transcriptions` (request/response). Model-level streaming exists (TTS
  `--stream`; STT `stream_transcribe`/streaming ASR models: Nemotron 3.5, Voxtral Realtime, Silero VAD).
  **Partial-transcript streaming over the HTTP server, warm/persistent workers, and cancellation are
  NOT documented** → esh should drive speech models **in-process**, not assume server support.
- **Breaking-change hazards for the bridge:** mlx-vlm `generate()` positional drift (image is the 4th
  positional; new `draft_model`/`draft_kind` kwargs); **transformers v5 pin conflict** between mlx-lm
  and mlx-vlm in one venv; ~0.5.0 attention-signature change; fast-moving mlx-vlm (0.6.x/0.7.0rc). →
  **pin versions deliberately; watch deprecation warnings.**

## C. llama.cpp
- **Speculative decoding reworked** `[AVAILABLE]`: `-md/--spec-draft-model` (old `--model-draft` still
  aliased), `--spec-draft-n-max/-n-min` (**old `--draft-max/--draft-min` removed**), and **`--spec-type`
  {draft-simple, draft-eagle3, draft-mtp, ngram-*}**. **EAGLE3 merged** (PR #18039, Jun 2026; Llama
  3.x/Qwen3/Gemma/GPT-OSS targets; MoE weaker). **n-gram/prompt-lookahead needs no draft model.**
  ⚠️ esh's bundled **b8660 uses the OLD draft flags** — bumping llama.cpp requires migrating them.
- **KV quant** `[AVAILABLE]`: `-ctk/-ctv` (f16/q8_0/q4_0/…); q8_0 K is the common near-free win.
- **Prompt-cache persistence** `[AVAILABLE]`: `--cache-prompt` (default on), `--cache-reuse N` (KV
  shifting), slot save/restore to disk (`--slot-save-path`, `POST /slots/{id}?action=save|restore`),
  `--cache-idle-slots`. Multi-slot/parallel (`-np`, `-cb`), `--kv-unified`, `/slots`, `/props`.
- Structured output (`--grammar`, `-j/--json-schema`) + reasoning (`--reasoning-format`,
  `--reasoning-budget`) already used by esh. Metal perf deltas since early 2026: `[CLAIMED/UNKNOWN]`
  (blog-sourced) — verify against release notes, benchmark locally.

## D. Apple Foundation Models (2026)
- On-device ~3B: `@Generable` guided generation, `Tool` calling, streaming, ~4K→~8K context (verify via
  `SystemLanguageModel.contextSize`), rank-32 LoRA adapters (retrain per base update) `[AVAILABLE]`.
- **New in 2026** `[CLAIMED, high-confidence; verify at build]`: vision input via `Attachment`; a
  Private Cloud Compute 32K reasoning model (`reasoningLevel`); a **`LanguageModel` protocol** letting
  any backend (incl. **`MLXLanguageModel`**) drive a `LanguageModelSession`; `response.usage` token
  accounting; built-in system tools (OCR/barcode/Spotlight-RAG); a Python SDK. **No raw HTTP server** —
  complements, doesn't replace, llama.cpp. The `LanguageModel` protocol + Python SDK are the esh-relevant
  integration surfaces.

## E. Speculative decoding landscape
EAGLE3 (now in llama.cpp) is the strongest general method `[AVAILABLE in llama.cpp]`; MTP practical when
the model ships heads (DeepSeek-V3, Qwen3.x; mlx-vlm `--draft-kind mtp`); **n-gram/prompt-lookahead**
needs no second model and helps most on repetitive/code/edit output `[AVAILABLE in llama.cpp]`. Realistic
batch-1 M-series expectation ~1.5–2.5x, **shrinking on MoE targets** (draft≈active-params) and novel text
— all `[CLAIMED]` pending local benchmark.

## F. Persistent local speech
- **STT:** `parakeet-mlx` (`transcribe_stream`, Swift wrapper) `[AVAILABLE]`; `whisper.cpp`
  (`whisper-stream`, native `--vad` Silero, Core ML/ANE) `[AVAILABLE]`.
- **TTS:** `kokoro-mlx` (gapless streaming) `[AVAILABLE]`; Qwen3-TTS/others.
- **Warm-serving** = load once in a persistent process, feed chunks, stream out — buildable today from
  primary repos. **VAD/turn-detection/barge-in** are compose-it-yourself (whisper `--vad` + endpointing);
  no turnkey primary-source component. First-audio latency figures `[CLAIMED]` — benchmark locally.

## G. Models on MLX now (candidates, quality `[CLAIMED]`)
- Text coding/reasoning: Qwen3.5/3.8 (2B–27B), Gemma 4 (~31B), MiniMax-M3, LiquidAI LFM2.5, GLM-5.3.
- Vision: Qwen3.5-VL, Gemma-3n (image+audio), **Muse-Glimmer-30B**.
- Speech: Kokoro-82M, Qwen3-TTS, Voxtral; Whisper-v3-turbo, Parakeet v3, Nemotron 3.5.
- **Sizing for esh:** 8 GB → ≤4B 4-bit; 16–24 GB → up to ~27–31B 4-bit; 32–48 GB → 30B VLM/MoE;
  64–96 GB → 70B-class or high-precision 30B.

### Muse Glimmer — verdict: **exists as an MLX build; Meta provenance UNVERIFIED**
`meta-models/Muse-Glimmer-30B` is live (HF API 200; arch `muse_glimmer`; image-text-to-text; ~610k
downloads), with MLX builds `mlx-community/Muse-Glimmer-30B-4bit` (`MuseGlimmerForConditionalGeneration`,
converted with mlx-vlm) + `-mxfp4`, a GGUF build, and it is **documented in the mlx-vlm README** with an
auto-detected `Muse-Glimmer-30B-assistant` DFlash drafter. **But** `meta-models` is *not* Meta's
established org (`facebook`/`meta-llama`), and `research.meta.ai` is *not* Meta's established domain
(`ai.meta.com`/`llama.com`) — a bare HTTP 200 doesn't prove first-party authenticity, and it postdates
the training cutoff. **Treat as an unverified candidate:** a real, downloadable 30B VLM with an MLX
build worth benchmarking, but confirm provenance on the actual HF model card / Meta's real channels
before esh recommends or bundles anything referencing it. On this Mac (32 GB) the 4-bit ~17 GB build is
size-feasible; the current gated `qwen3.5-9b` situation shows why *esh must benchmark, not trust*.

## H. Implications for esh 2.1
1. **Warm speech is real and STT-first** (proof A) — persistent in-process STT/TTS (mlx-audio server
   streaming is undocumented) → M12/M13.
2. **Speculative decoding is a legitimate, benchmark-first `Auto` candidate** on both backends; start
   with GGUF **n-gram** (no draft model) and draft-model spec (flags already in b8660); MLX draft-model
   via mlx-lm, MTP/DFlash via mlx-vlm. Mind KV-trim vs spec-decode exclusivity → M17.
3. **Prompt-cache persistence** is mature on both backends → context/cache policy in the ExecutionPlan
   (M15/M18).
4. **Apple FM `LanguageModel` protocol + Python SDK** are new integration surfaces; FM stays a
   complement (no server). Re-audit FM capabilities (vision, PCC, usage) for the Web/capability layer.
5. **Dependency discipline is a first-class risk** — mlx-lm/mlx-vlm transformers-v5 pin conflict and
   `generate()` drift can break the bridge; pin + gate on deprecation warnings (see risk analysis).
6. **Trust nothing unbenchmarked** — 2026 blog benchmarks are largely fabricated; Muse-Glimmer
   provenance is unconfirmed. esh's measured-on-this-Mac evidence layer is the antidote.
