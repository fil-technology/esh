# Other Open-Weight Coding Models + M1 Pro/32GB Inference Feasibility

Research date: 2026-10-14. Target HW: MacBook Pro M1 Pro, 32GB unified memory, weights on external SSD (~1 GB/s measured sequential read), runtime = MLX (`mlx_lm`, 4/3-bit) or GGUF/llama.cpp (Metal; Q4/Q3/IQ/K-quants). Baseline: Qwen3-30B-A3B 4-bit MLX, ~17.2 GB resident, **~37 tok/s measured**.

Scope note: Qwen, DeepSeek, GLM are covered by other agents and are **excluded** here except as benchmark comparators.

Evidence labels used throughout:
- **VERIFIED FACT** = stated on a primary/official source (model card, official repo/docs, official blog).
- **PUBLISHED-BENCHMARK** = a benchmark number printed on a primary source (official model card / tech report / vendor post), with URL.
- **ESTIMATE** = my derivation/extrapolation; not a measured number. Clearly marked.

A recurring hazard during this research: SEO/vendor blogs invented models and numbers ("Qwen3.6-27B 77.2", "Qwen3.8-27B", "Gemma 4 31B 80.0"). **None of those were confirmable on a primary source and are NOT treated as fact below.**

---

## JOB A — Non-Qwen/DeepSeek/GLM coding models

### Fit rule of thumb (32GB)
Usable budget after macOS (~6–8 GB) ≈ **~22–24 GB** for weights+KV+overhead (default Metal wired limit ~21 GB on 32GB; raisable to ~26 GB via `iogpu.wired_limit_mb`). A model is "fits" if 4-bit weights + working KV stay under that. See Job B memory math.

---

### 1. Devstral Small 2 (24B)  — TOP FIT, best agentic coding
- **HF id:** `mistralai/Devstral-Small-2-24B-Instruct-2512` (MLX: `mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit`). **VERIFIED FACT** (repos exist).
- **Release:** 2025-12-09. **VERIFIED FACT** (Mistral news + legal page).
- **Arch:** 24B **dense** transformer. Also accepts image input. **VERIFIED FACT** (Mistral news page).
- **Context:** 256K tokens. **VERIFIED FACT** (Mistral news page).
- **License:** **Apache 2.0** (commercial OK). **VERIFIED FACT.** (Its bigger sibling Devstral 2 / 123B is Modified MIT.)
- **Coding benchmark:** **SWE-bench Verified = 68.0%**. **PUBLISHED-BENCHMARK** (mistral.ai/news/devstral-2-vibe-cli). The only benchmark on the page besides a human win-rate eval. Scaffold not re-stated on that page but Devstral family uses OpenHands.
- **Tool/agentic:** Purpose-built agentic coding model; vendor lists Cline/OpenHands/Claude Code/Kilo integrations. **VERIFIED FACT.**
- **Quants/size:** MLX 4-bit repo exists; a 24B at 4-bit (gs64) ≈ **~13–14 GB on disk/resident** (ESTIMATE from 24B×~4.5 bpw). An "OptiQ" mixed 4/8-bit (~5 bpw) variant also exists (larger). GGUF widely available (Unsloth/bartowski lineage) — Q4_K_M ≈ ~14–15 GB (ESTIMATE).
- **Verdict:** **Fits comfortably.** Highest verified SWE-bench of any <35B open model found. Dense 24B → decode slower than the MoE baseline (see throughput). Note: Mistral API has since marked Devstral 2 "deprecated" pointing to Mistral Medium 3.5, but **open weights remain on HF** (VERIFIED FACT).

### 2. OpenAI gpt-oss-20b — lightest, fastest, strong tool-calling
- **HF id:** `openai/gpt-oss-20b` (MLX: `mlx-community/gpt-oss-20b-MXFP4-Q4`, `...-OptiQ-4bit`; many GGUF). **VERIFIED FACT.**
- **Release:** 2025-08-05. **VERIFIED FACT** (OpenAI model card).
- **Arch:** **MoE**, 20.9B total / **3.6B active**, 24 layers. (120b sibling: 116.8B/5.1B, 36 layers.) **VERIFIED FACT** (model card, via search of the card).
- **Context:** 128K. **VERIFIED FACT.**
- **License:** **Apache 2.0** (+ a usage policy doc). **VERIFIED FACT.**
- **Coding benchmarks (high-reasoning):** **SWE-bench Verified = 60.7%** (20b); 62.4% (120b). Codeforces Elo ~2463 (120b, no tools). **PUBLISHED-BENCHMARK** (OpenAI gpt-oss model card, arXiv 2508.10925 / cdn.openai.com PDF). The card also lists lower scores at lower reasoning levels (e.g. 20b 37.4/53.2 at other settings).
- **Tool/agentic:** Trained for tool use / Codex-CLI-style terminal tool; community notes clean tool-call JSON. **VERIFIED FACT** (card describes terminal-tool eval).
- **Quants/size:** Native MXFP4 MoE. Reported **peak ~11.3 GB** running `mlx_lm.generate` on the MXFP4-Q4 repo; a community MXFP4 build totals ~13.8 GB. **PUBLISHED/community-measured.**
- **Verdict:** **Fits very comfortably with large KV headroom.** Because only 3.6B params are active, decode is **fast** (MoE behaves like a ~4B dense for bandwidth). Best "fast agentic + tool-calling" pick. Slightly below Devstral on SWE-bench but far lighter.

### 3. ByteDance Seed-OSS-36B-Instruct — strongest raw coding scores, but heavy/slow
- **HF id:** `ByteDance-Seed/Seed-OSS-36B-Instruct` (GGUF: `bartowski/ByteDance-Seed_Seed-OSS-36B-Instruct-GGUF`). **VERIFIED FACT.**
- **Release:** 2025-08-20. **VERIFIED FACT** (model card).
- **Arch:** 36B **dense** (64 layers, GQA, SwiGLU; no expert routing → dense). **VERIFIED FACT** (card; dense is inference from arch but strongly supported).
- **Context:** 512K native. **VERIFIED FACT.**
- **License:** **Apache 2.0.** **VERIFIED FACT.**
- **Coding benchmarks (Instruct):** **LiveCodeBench v6 (02–05/2025) = 67.4**; **SWE-bench Verified (OpenHands) = 56**; SWE-bench Verified (AgentLess 4×10) = 47; Multi-SWE-Bench = 17. TAU1-Retail 70.4 / Airline 46. **PUBLISHED-BENCHMARK** (official HF model card table). (HumanEval 76.8 / MBPP 80.6 are reported for the *Base* model only.)
- **Tool/agentic:** Explicit agentic/tool-use focus; vLLM `--tool-call-parser seed_oss`. **VERIFIED FACT.**
- **Quants/size (GGUF, bartowski — VERIFIED FACT):** Q4_K_M **21.76 GB**, Q4_K_S 20.70, Q3_K_XL 19.84, Q5_K_M 25.59, Q6_K 29.67, Q8_0 38.42. (Docker UD-Q4_K_XL ~20.5 GB.)
- **Verdict:** **Fits but TIGHT.** Q4_K_M (21.76 GB) + macOS leaves little KV room → likely needs Q3_K_XL/IQ3 or quantized KV for long context. Being **dense 36B**, decode is **slow** (must read ~20 GB/token → ~7–10 tok/s ESTIMATE). Best when you want the highest LiveCodeBench and can tolerate low tok/s.

### Also-relevant, fit but weaker/secondary
- **Devstral Small 2507 (24B dense):** `mistralai/Devstral-Small-2507`. Apache 2.0, 128K ctx. **SWE-bench Verified = 53.6% (OpenHands)** — PUBLISHED-BENCHMARK (HF card). **Superseded by Devstral Small 2 (68.0%)**; only pick it if you need the older/stable one. Mature MLX+GGUF quant ecosystem.
- **Mistral Small 3.2 24B Instruct (2506):** `mistralai/Mistral-Small-3.2-24B-Instruct-2506`. Apache 2.0. General model (not coder). Vendor-reported coding gains: HumanEval Plus 88.99→92.90, MBPP pass@5 74.63→78.33 (PUBLISHED-BENCHMARK via AWS/press citing Mistral; HF card is authoritative). Fits (4-bit ~13–14 GB). Reasonable general+code generalist; weaker agentic than Devstral.
- **Google Gemma 3 27B-it:** `google/gemma-3-27b-it`. 128K ctx. **License = custom Gemma Terms (NOT OSI; commercial allowed w/ conditions)** — VERIFIED FACT. **LiveCodeBench = 29.7** (27B), 24.6 (12B) — PUBLISHED-BENCHMARK (Gemma 3 model card + tech report arXiv 2503.19786). (DeepMind product page's 54.4% is mislabeled Bird-SQL.) Fits (4-bit ~15–16 GB) but **coding is comparatively weak**; better as a general/multimodal model.
- **CodeGemma (2B/7B):** older (built on Gemma 1), 8K ctx. Largely historical; not competitive in 2026.
- **IBM Granite 4.0-H-Small:** `ibm-granite/granite-4.0-h-small`. Released 2025-10-02, **Apache 2.0** (VERIFIED FACT). **MoE hybrid Mamba2** 32B total / **9B active** (72 experts, 10 active). **No primary coding benchmark (HumanEval/LCB/SWE) found** — IBM emphasizes agentic/function-calling; say "no primary source" for coding scores. Fits (4-bit ~18 GB ESTIMATE). Hybrid-Mamba support in MLX/llama.cpp is less mature than plain transformers — verify runtime support before committing.
- **StarCoder2-15B:** `bigcode/starcoder2-15b`. Feb 2024, **BigCode OpenRAIL-M** (use restrictions; not OSI/Apache). Completion model, not chat/agentic. ~9 GB GGUF. **Historical interest only** in 2026.

### Clearly NOT practical on 32GB (mark and move on)
- **Llama 4 Scout 17B-16E:** 109B total MoE / 17B active. Llama 4 Community License (not OSI). LiveCodeBench 32.8 (HF card, PUBLISHED-BENCHMARK). 4-bit total weights ≈ **~55–60 GB** → **Not practical (32GB).** (Expert-streaming from a 1 GB/s SSD is not viable — see Job B.)
- **Moonshot Kimi-K2:** ~1.04T total / ~32.6B active MoE, modified-MIT. **Not practical (32GB)** by orders of magnitude.
- **Mistral Devstral 2 (123B dense):** Modified MIT, SWE-bench Verified 72.2% (PUBLISHED-BENCHMARK, Mistral news). Needs ≥4× H100. **Not practical (32GB).**
- **OpenAI gpt-oss-120b:** 117B MoE. 4-bit ≈ ~60+ GB. **Not practical (32GB).**
- **Cohere Command A+ :** ~218B, Apache 2.0. **Not practical (32GB).** (Older Command R/R+ were CC-BY-NC — non-commercial.)

---

## JOB B — Inference feasibility & optimization (M1 Pro / 32GB)

### B1. MLX (`mlx_lm`, `mlx-swift`) — status Oct 2026
- **Quantization (VERIFIED FACT, `mlx_lm/convert.py`):** affine quantization; flags `--q-bits` (default **4**) and `--q-group-size` (default **64**). Supported bit widths: **2, 3, 4, 6, 8**. Group size = #weights sharing one scale+bias; smaller groups (e.g. 32) fit the distribution better but add ~0.125 bytes/param overhead. Mixed-precision recipes also default gs=64. WWDC25 session 298 uses 4-bit/gs64 as the canonical recipe.
- **3-bit reality:** 3-bit is *supported* and some `mlx-community`/OptiQ mixed 3/4-bit models are published, but 4-bit (gs64) is the de-facto standard; 3-bit flat shows a clear quality drop (consistent with llama.cpp's sub-4-bit perplexity cliff below). **3-bit is usable mainly as mixed-precision (keep sensitive layers at 4/6-bit), not flat.** ESTIMATE/qualitative — no single primary MLX 3-bit quality table found.
- **Prompt caching / KV reuse (VERIFIED FACT, mlx-lm README):** YES. `mlx_lm.cache_prompt --prompt-cache-file foo.safetensors` creates a cache; `mlx_lm.generate --prompt-cache-file foo.safetensors` reuses it (cached prompt is a prefix; `--model` not even required). `--max-kv-size` = rotating fixed-size KV; `--prefill-step-size` (default 2048). This is a real win for a fixed long system/context prompt reused across queries.
- **Speculative decoding (draft model):** Present in the codebase (`generate` accepts a draft model; server path exists) **but fragile**: `mlx-lm` issue #1446 — speculative generation fails on some targets because the prompt cache (`ArraysCache`) is "not trimmable" (fix PR opened). An EAGLE-3 prototype discussion (#890) found that for already-fast 4-bit small models (~114 tok/s for 4-bit 8B) draft overhead often **fails to pay off**. Better-supported drafter work (DFlash/EAGLE-3) currently lives in `mlx-vlm`/Unsloth, not core `mlx_lm`. **Verdict: don't rely on MLX spec-decoding as a speedup today; verify on your exact model first.** (VERIFIED FACT that it's buggy; benefit is workload-dependent.)
- **Quantized KV cache:** `mlx_lm` supports quantized KV (kv-bits option) to extend context — treat exact flag as to-verify (ESTIMATE); `--max-kv-size` rotation is the documented fallback.

### B2. llama.cpp / GGUF (Metal) — status Oct 2026
- **K-quants vs IQ-quants (VERIFIED/PUBLISHED):** IQ (i-quants) pack smaller at equal nominal bits: for Llama-3.1-8B, **IQ4_XS ≈ 4.46 bpw (4.17 GiB)** vs **Q4_K_M ≈ 4.89 bpw (4.58 GiB)**. I-quants historically **decode slower on CPU**; on Metal GPU the gap is smaller but K-quants still tend to give higher tok/s. Sub-4-bit cliff: llama.cpp's own quantize table (LLaMA-7B) shows **Q3_K_M +0.2496 ppl vs Q4_K_M +0.0532 ppl** — i.e. the quality penalty jumps ~5× going 4→3 bit; Q2_K is ~16× Q4_K_M. **PUBLISHED-BENCHMARK** (llama.cpp quantize help table). **Practical:** stay at Q4_K_M/IQ4_XS when it fits; drop to Q3_K_M/IQ3_XXS only when memory forces it, expecting real quality loss; IQ3_XXS ≈ same size as Q3_K_M (~3.06 bpw) but no primary head-to-head quality table found (say "no primary source").
- **Metal perf M1 Pro (PUBLISHED-BENCHMARK, llama.cpp Discussion #4167, LLaMA-7B, 16 GPU cores):** Q4_0 **TG 36.41 tok/s / PP 266.25 tok/s**; Q8_0 TG 22.34 / PP 270.37; F16 TG 12.75 / PP 302.14. (14-core: Q4_0 TG 35.52 / PP 232.55.) This is the key bandwidth anchor — note user's Qwen3-30B-A3B MLX at ~37 tok/s matches 7B-class decode because only ~3B params are active.
- **Speculative decoding (`--draft`/`-md`, `-ngld`):** supported (`docs/speculative.md`), BUT on Apple-Silicon unified memory it is **frequently a net loss** — draft+target compete for the same ~200 GB/s bandwidth. llama.cpp issue #23752: MTP spec-decoding slower at *every* config on Metal (e.g. 9B 25→19 tok/s; 5–14× regression on a 35B-A3B MTP). Community reports ~11–24% net loss for draft-model spec-decode on Metal. **Verdict: default OFF on M1 Pro unless you measure a win with a tiny (~0.5–1B) same-family draft.** (VERIFIED/community.)
- **Grammar-constrained output (GBNF) (VERIFIED FACT):** supported via `--grammar` / `--grammar-file` and `grammar` field on server endpoints; JSON-schema→GBNF conversion available. Caveat: `x? x? ...` repetition patterns can make sampling extremely slow — use `x{0,N}`. Great for forcing structured/tool-call JSON locally.
- **Prompt cache / slot KV reuse (VERIFIED FACT):** `--cache-prompt` (on by default) + `--cache-reuse N`; prefix reuse requires same slot + exact leading prefix + same server lifetime. Keep system prompt byte-stable; check `timings.cache_n`. Known correctness bugs under concurrency / LoRA scale changes (issues #27148, LoRA-scale report) — fine for single-user local use.

### B3. Memory math for 32GB
- **Usable budget (VERIFIED/derived):** 32 GB − macOS/apps (~6–8 GB) ⇒ **~24–26 GB** physical headroom. Metal GPU wired-memory default limit ≈ 21 GB on a 32GB Mac (raisable via `sudo sysctl iogpu.wired_limit_mb=…` to ~26 GB). User already runs a 17.2 GB model, confirming ~21 GB+ is reachable.
- **Total ≈ quantized weights + KV cache + activation/overhead (~0.5–1.5 GB).**
- **KV-cache-per-token formula (VERIFIED FACT):**
  `bytes/token = 2 (K+V) × n_layers × n_kv_heads × head_dim × bytes_per_elem`
  (fp16 ⇒ 2 bytes; Q8 KV ⇒ 1 byte; Q4 KV ⇒ 0.5 byte.)
- **Worked examples** (layer/head counts are typical config values — ESTIMATE where not fetched; formula itself is exact):
  - **~8B dense (Llama-3.1-8B: 32L, 8 KV heads, head_dim 128, fp16):** 2×32×8×128×2 = **128 KB/token** → 8k = **1.0 GB**, 32k = **4.0 GB**.
  - **~14B dense (48L, 8 KV heads, hd 128):** 192 KB/tok → 8k = **1.5 GB**, 32k = **6.0 GB**.
  - **24B Devstral-class (≈40L, 8 KV heads, hd 128):** 160 KB/tok → 8k = **1.25 GB**, 32k = **5.0 GB**.
  - **30B-A3B MoE (Qwen3-30B-A3B: 48L, ~4 KV heads, hd 128):** 96 KB/tok → 8k = **0.75 GB**, 32k = **3.0 GB**. (MoE's small KV-head count is why the baseline leaves lots of room.)
- **Where context forces quantized KV:** a 24B 4-bit (~13–14 GB weights) + 32k fp16 KV (~5 GB) + overhead ≈ **~20 GB → brushing the default wired limit.** At 64k+ or for the dense 36B (Seed-OSS, ~20 GB weights at Q4_K_M), you **must** use Q8 (halve) or Q4 (quarter) KV — llama.cpp `--cache-type-k/--cache-type-v q8_0|q4_0`, or MLX quantized KV / `--max-kv-size`. Below ~8k context, fp16 KV is fine for everything that fits.

### B4. Throughput reality on M1 Pro (~200 GB/s; decode is bandwidth-bound)
Decode tok/s ≈ memory_bandwidth ÷ bytes_read_per_token (dominated by *active* weights at 4-bit). PP (prefill) is compute-bound.
- **7B dense 4-bit:** **~36 tok/s decode, ~230–270 tok/s prefill** — **PUBLISHED-BENCHMARK** (llama.cpp #4167).
- **14B dense 4-bit:** **~16–22 tok/s** decode — **ESTIMATE** (~half of 7B; ~8 GB read/token).
- **24B dense 4-bit (Devstral Small 2, Mistral 3.2):** **~10–14 tok/s** decode — **ESTIMATE** (~13 GB read/token).
- **30B-A3B MoE 4-bit:** **~37 tok/s** — **MEASURED by user** (matches 7B-class because ~3B active). gpt-oss-20b (3.6B active) should land **~40–55 tok/s ESTIMATE**.
- **36B dense 4-bit (Seed-OSS):** **~7–10 tok/s** decode — **ESTIMATE** (~20 GB read/token; slowest of the fitting set).
- **Takeaway:** MoE decode speed tracks **active** params, not total → a well-chosen MoE (gpt-oss-20b, or staying on the Qwen3-30B-A3B family) is far faster than any dense ≥24B at similar quality.

### B5. SSD (1 GB/s exFAT/USB) implications — keep models RESIDENT
- **VERIFIED (user measurement):** ~1 GB/s sequential read ceiling (exFAT/USB).
- **Cold-start load:** load time ≈ size ÷ 1 GB/s. **17 GB model ≈ 17 s+**; 21.76 GB (Seed-OSS Q4_K_M) ≈ **~22 s+**; plus quant/mmap setup. (ESTIMATE from the measured ceiling.)
- **Expert-streaming / mmap-from-SSD for MoE is NOT viable:** at 1 GB/s, paging experts per token would collapse decode from tens of tok/s to a trickle. Decode needs ~hundreds of GB/s (RAM), not ~1 GB/s (SSD). → **Recommendation: quantize-to-fit so the whole model is RAM-resident; never rely on disk streaming / partial offload.** This directly rules out Llama 4 Scout / gpt-oss-120b style "big MoE, stream experts" approaches on this box.
- **Mitigations:** keep the chosen model on the fastest available volume; accept the one-time ~15–25 s cold load; keep a server process warm (llama-server / mlx_lm server) to avoid reloading; use prompt cache to avoid re-prefill.

---

## Bottom line
- **Top 3 non-Qwen/DeepSeek/GLM that fit 32GB:** (1) **Devstral Small 2 24B** — best verified agentic coding (SWE-bench Verified 68.0%), Apache 2.0, 256K, ~13–14 GB @4-bit; dense so ~10–14 tok/s. (2) **gpt-oss-20b** — fastest (3.6B active, ~11 GB, likely 40–55 tok/s), Apache 2.0, strong tool-calling, SWE-bench Verified 60.7%. (3) **Seed-OSS-36B-Instruct** — highest LiveCodeBench (67.4) / SWE-bench 56, Apache 2.0, 512K; but tight fit (Q4_K_M 21.76 GB) and slow (dense 36B, ~7–10 tok/s).
- **Feasibility verdicts:** MLX and GGUF/llama.cpp both viable; MLX integrates cleanest on Apple Silicon and matches the user's current stack. **Speculative decoding: effectively unavailable as a reliable speedup** on M1 Pro (MLX draft path buggy; llama.cpp spec-decode is a net loss on unified memory) — don't count on it. **Prompt caching: solid win on both** (mlx_lm.cache_prompt; llama.cpp --cache-prompt/--cache-reuse). **GBNF grammar** (llama.cpp) is the clean route to constrained/tool-call JSON. **KV/context:** fp16 KV fine ≤8k for all fitting models; at 32k+ or for the 36B, use Q8/Q4 KV. **Realistic 4-bit decode:** 7B ~36 (measured), 14B ~16–22, 24B dense ~10–14, 30B-A3B MoE ~37 (measured), 36B dense ~7–10 tok/s. **Keep weights RAM-resident; SSD at 1 GB/s means ~17–22 s cold loads and makes expert-streaming non-viable → quantize-to-fit.**

---

## Sources
Primary (preferred):
- Devstral 2 / Small 2 — https://mistral.ai/news/devstral-2-vibe-cli/ ; legal: https://legal.mistral.ai/ai-governance/models/devstral-small-2
- Devstral Small 2507 card — https://huggingface.co/mistralai/Devstral-Small-2507
- Devstral Small 2 MLX 4-bit — https://huggingface.co/mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit
- gpt-oss model card — https://arxiv.org/abs/2508.10925 ; https://cdn.openai.com/pdf/419b6906-9da6-406c-a19d-1bb078ac7637/oai_gpt-oss_model_card.pdf
- gpt-oss-20b MLX (peak-mem discussion) — https://huggingface.co/spaces/mlx-community/README/discussions/21
- Seed-OSS-36B-Instruct card — https://huggingface.co/ByteDance-Seed/Seed-OSS-36B-Instruct
- Seed-OSS-36B GGUF sizes — https://huggingface.co/bartowski/ByteDance-Seed_Seed-OSS-36B-Instruct-GGUF
- Mistral Small 3.2 (AWS/press citing Mistral) — https://aws.amazon.com/blogs/machine-learning/mistral-small-3-2-24b-instruct-2506-is-now-available-on-amazon-bedrock-marketplace-and-amazon-sagemaker-jumpstart/
- Gemma 3 model card — https://ai.google.dev/gemma/docs/core/model_card_3 ; tech report https://arxiv.org/pdf/2503.19786
- IBM Granite 4.0-H-Small card — https://huggingface.co/ibm-granite/granite-4.0-h-small ; repo https://github.com/ibm-granite/granite-4.0-language-models
- Llama 4 Scout card — https://huggingface.co/meta-llama/Llama-4-Scout-17B-16E
- StarCoder2 — https://huggingface.co/bigcode/starcoder2-15b ; report https://arxiv.org/pdf/2402.19173
- Cohere Command A+ — https://venturebeat.com/technology/cohere-cracks-lossless-quantization-and-native-citations-with-first-full-apache-2-0-licensed-open-model-command-a
- Kimi-K2 (size/license) — https://openrouter.ai/moonshotai/kimi-k2

Job B / feasibility:
- mlx-lm (prompt cache, quant flags) — https://github.com/ml-explore/mlx-lm ; convert.py https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/convert.py
- mlx-lm speculative decoding bug — https://github.com/ml-explore/mlx-lm/issues/1446 ; EAGLE-3 analysis https://github.com/ml-explore/mlx-lm/discussions/890
- Apple WWDC25 MLX LLM session — https://developer.apple.com/videos/play/wwdc2025/298/
- llama.cpp M1 Pro perf — https://github.com/ggml-org/llama.cpp/discussions/4167
- llama.cpp spec-decode docs — https://github.com/ggml-org/llama.cpp/blob/master/docs/speculative.md ; Metal MTP regression https://github.com/ggml-org/llama.cpp/issues/23752
- GGUF K vs IQ quant comparison — https://kaitchup.substack.com/p/choosing-a-gguf-model-k-quants-i
- llama.cpp perplexity/quant table — https://github.com/ggml-org/llama.cpp/tools/perplexity/README.md
- llama.cpp KV cache reuse tutorial — https://github.com/ggml-org/llama.cpp/discussions/13606
- GBNF grammar README — https://github.com/ggml-org/llama.cpp/blob/master/grammars/README.md

Caution (NOT used as fact; SEO/vendor blogs that fabricated models/numbers): morphllm, kilo.ai, codersera "Qwen3.5–3.8", openclawdc, "Gemma 4 31B", etc.
