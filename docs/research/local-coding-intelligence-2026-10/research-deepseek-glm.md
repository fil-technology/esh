# DeepSeek & GLM (Zhipu/Z.ai) open-weight coding models for local use on M1 Pro / 32GB

Research date: 2026-10-14. Target host: MacBook Pro M1 Pro, 32GB unified memory, weights on external SSD, runtimes = MLX (4/3-bit) or GGUF/llama.cpp (Q4/Q3/IQ/K-quants).

Baseline the user actually runs: **Qwen3-30B-A3B 4-bit MLX ≈ 17.2 GB resident, ~37 tok/s measured** on this machine (MoE, 3B active). Everything below is related to that anchor.

Labels used throughout:
- **VERIFIED FACT** = stated on an official/primary page (HF model card, DeepSeek/Z.ai docs, GitHub).
- **PUBLISHED-BENCHMARK** = a numeric score from a primary source (official model card / tech report), with URL.
- **ESTIMATE** = my engineering inference (fit math, tok/s), not from a source.

Fit math used for ESTIMATEs (M1 Pro / 32GB):
- 4-bit weights ≈ params(B) × ~0.53 GB (incl. quant metadata); 3-bit ≈ ×0.42; IQ2 ≈ ×0.30.
- Usable budget ≈ 32GB − ~6–8GB OS/wired/other ≈ **22–24GB for model + KV cache**.
- MoE with low active params decodes fast (compute ∝ active params); dense N-B decodes slower (compute ∝ all N).

---

## TL;DR — what actually fits 32GB (ranked for coding)

| Rank | Model | HF id | Arch | 4-bit size (ESTIMATE) | Fit class | Why |
|---|---|---|---|---|---|---|
| 1 | **GLM-4.7-Flash** | `zai-org/GLM-4.7-Flash` | MoE 30B-A3B | ~16–18 GB | **FITS — drop-in baseline peer** | Same size/shape as the Qwen3-30B-A3B baseline; MIT; newest; best published coding scores of anything that fits |
| 2 | **GLM-4-32B-0414** | `zai-org/GLM-4-32B-0414` | Dense 32B | ~17–18 GB | **FITS (slower decode)** | Dense 32B, strong non-reasoning coder/tool-caller, MIT |
| 3 | **DeepSeek-Coder-V2-Lite-Instruct** | `deepseek-ai/DeepSeek-Coder-V2-Lite-Instruct` | MoE 16B-A2.4B | ~9–10 GB | **FITS — very fast** | Fastest decode (2.4B active), pure-coder, 128k ctx; but 2024-era |
| 4 | **DeepSeek-R1-0528-Qwen3-8B** | `deepseek-ai/DeepSeek-R1-0528-Qwen3-8B` | Dense 8B | ~4.5–5 GB | **FITS easily** | Best small reasoning-coder (LCB 60.5); huge headroom for ctx |
| 5 | **GLM-Z1-32B-0414** | `zai-org/GLM-Z1-32B-0414` | Dense 32B | ~17–18 GB | **FITS (reasoning)** | Reasoning variant of #2 |
| 6 | **DeepSeek-R1-Distill-Qwen-32B** | `deepseek-ai/DeepSeek-R1-Distill-Qwen-32B` | Dense 32B | ~18 GB | **FITS (reasoning, slow)** | Older (Jan 2025) Qwen2.5-based reasoning distill |
| 7 | **DeepSeek-R1-Distill-Qwen-14B** | `deepseek-ai/DeepSeek-R1-Distill-Qwen-14B` | Dense 14B | ~8 GB | **FITS easily** | Mid reasoning distill |
| 8 | **CodeGeeX4-All-9B** | `zai-org/codegeex4-all-9b` | Dense 9B | ~5 GB | **FITS easily** | 2024 GLM-4-9B-based coder, 128k, repo-level features; non-commercial-ish license |

**Not practical (32GB):** GLM-4.5-Air (106B-A12B), GLM-4.6 (~355B), GLM-4.7 (~355B/357B), DeepSeek-V3.1 (685B), DeepSeek-V3.2 / V3.2-Exp / V3.2-Speciale (685B). See bottom section.

---

## FITTING CANDIDATES — detail

### 1. GLM-4.7-Flash  ⭐ top pick (direct baseline peer)
- **HF id:** `zai-org/GLM-4.7-Flash`. MLX builds: `lmstudio-community/GLM-4.7-Flash-MLX-4bit` (+ 6bit, 8bit). GGUF: `bartowski/zai-org_GLM-4.7-Flash-GGUF`, `unsloth/GLM-4.7-Flash-GGUF`. — VERIFIED FACT
- **Release:** 2025 (exact date not on the HF card; GLM-4.7 generation, late 2025). — partially verified (year only)
- **Architecture:** MoE, **~30B total / ~3B active ("30B-A3B")**; safetensors metadata reports 31B; expert count not stated on card. — VERIFIED FACT
- **Context:** card states 131072 as a *generation/output* cap; full context window not explicitly numbered on the card (GLM-4.x family is 128K-class). — partially verified
- **License:** **MIT** (commercial OK). — VERIFIED FACT
- **Coding benchmarks (from the official HF card):** — PUBLISHED-BENCHMARK
  - SWE-bench Verified: **59.2**
  - LiveCodeBench v6: **64.0**
  - τ²-Bench (agentic tool-use): **79.5**
  - BrowseComp (agentic browsing): **42.8**
  - Terminal-Bench 2: evaluated (no single score quoted in card text)
  - URL: https://huggingface.co/zai-org/GLM-4.7-Flash
- **Tool-calling / agentic:** Yes — first-class. Serving uses a `glm47` tool-call parser + `--enable-auto-tool-choice`; `glm45` reasoning parser. **Hybrid "Preserved Thinking mode"** recommended for multi-turn agentic tasks. — VERIFIED FACT
- **Swift/SwiftUI or TS/Next.js specifics:** unknown (no language-specific claim on card).
- **ESTIMATE (fit + speed):** 4-bit ≈ 16–18 GB resident — **essentially identical footprint to the Qwen3-30B-A3B baseline**, and same MoE shape (≈3B active), so expect **~30–40 tok/s, comparable to the ~37 tok/s baseline**. 8k–32k KV fits comfortably in 32GB. This is the clearest "upgrade in the same slot" — newer, MIT, higher published coding/agentic scores than the baseline's class. **Best bet for coding that fits.**

### 2. GLM-4-32B-0414  (dense, strong tool-caller, non-reasoning)
- **HF id:** `zai-org/GLM-4-32B-0414`. MLX: `mlx-community/GLM-4-32B-0414-4bit` (+ 8bit). GGUF widely available. — VERIFIED FACT
- **Release:** GLM-4-0414 collection (early 2025; "0414" = Apr 14). — partially verified
- **Architecture:** **Dense, 32B** (33B in BF16 safetensors). — VERIFIED FACT
- **Context:** 32K (card footnote refers to "the 32K context limit"; no YaRN by default). — VERIFIED FACT
- **License:** **MIT**. — VERIFIED FACT
- **Benchmarks (official HF card):** — PUBLISHED-BENCHMARK
  - SWE-bench Verified: **33.8 (Moatless) / 30.7 (Agentless) / 27.2 (OpenHands)**
  - BFCL-v3 (function calling) Overall: **69.6**; MultiTurn: 41.5
  - TAU-Bench Retail 68.7 / Airline 51.2; IFEval 87.6
  - (No LiveCodeBench/HumanEval/Aider on card.)
  - URL: https://huggingface.co/zai-org/GLM-4-32B-0414
- **Tool-calling:** Yes — JSON tool calls, strengthened via rejection sampling + RL; works in Transformers/vLLM/SGLang. — VERIFIED FACT
- **Swift/TS specifics:** unknown. Card emphasizes engineering code generation + web design.
- **ESTIMATE:** 4-bit ≈ 17–18 GB → **fits**. But **dense 32B decodes slower than the MoE baseline** (all 32B active): expect roughly **~8–13 tok/s** on M1 Pro. Good choice when you want a non-reasoning, deterministic coder with solid function-calling and don't mind lower throughput. Note the modest SWE-bench (uses older agent scaffolds).

### 3. DeepSeek-Coder-V2-Lite-Instruct  (fastest; pure coder; 2024-era)
- **HF id:** `deepseek-ai/DeepSeek-Coder-V2-Lite-Instruct`. GGUF: `lmstudio-community/DeepSeek-Coder-V2-Lite-Instruct-GGUF` (Q4_K_M ≈ 10.4 GB). MLX: community builds exist but no single canonical mlx-community pin confirmed in this pass. — VERIFIED FACT (GGUF); MLX = check hub
- **Release:** June 2024. — VERIFIED FACT
- **Architecture:** **MoE, 16B total / 2.4B active** (DeepSeekMoE). — VERIFIED FACT
- **Context:** **128K**. — VERIFIED FACT
- **License:** DeepSeek Model License (metadata "other"); commercial use generally permitted but **verify LICENSE file**. — partially verified
- **Benchmarks (official GitHub README):** — PUBLISHED-BENCHMARK
  - HumanEval **86.4**, MBPP+ **61.8**, USACO 44.4 (an older table revision shows 81.1 / 68.8).
  - URL: https://github.com/deepseek-ai/DeepSeek-Coder-V2 ; paper https://arxiv.org/pdf/2406.11931
- **Tool-calling:** function-calling supported in V2 family; older chat template.
- **Swift/TS specifics:** unknown (multilingual coder; 338 langs claimed in paper).
- **ESTIMATE:** 4-bit ≈ 9–10 GB → **fits with large headroom**; **2.4B active → fastest decode of this set (likely >40 tok/s)** and cheap long-context. Downside: **2024 model**, weaker on modern agentic/repo tasks and no reasoning. Best when you want a snappy inline/autocomplete-style coder or a fast draft model.

### 4. DeepSeek-R1-0528-Qwen3-8B  (best small reasoning-coder)
- **HF id:** `deepseek-ai/DeepSeek-R1-0528-Qwen3-8B` (MIT, ~8.2B, Qwen3-8B arch, R1-0528 tokenizer). — VERIFIED FACT (MIT/arch); mirror-confirmed
- **Release:** 2025-05-29. — VERIFIED FACT (mirror)
- **Architecture:** Dense 8B (Qwen3-8B base), distilled from DeepSeek-R1-0528 reasoning traces. — VERIFIED FACT
- **Benchmarks (official card):** — PUBLISHED-BENCHMARK
  - LiveCodeBench (2408–2505): **60.5**; AIME24 86.0 / AIME25 76.3; GPQA-D 61.1.
  - URL: https://huggingface.co/deepseek-ai/DeepSeek-R1-0528-Qwen3-8B (table mirrored at https://huggingface.co/ManuelZnnmc/DeepSeek-R1-0528/blob/main/README.md)
- **Tool-calling:** run like Qwen3-8B; reasoning model (emits `<think>`), temp ~0.6.
- **ESTIMATE:** 4-bit ≈ 4.5–5 GB → **fits trivially**, room for full 32k+ ctx. Decode very fast (8B dense), but **reasoning burns output tokens**, so wall-clock per answer is longer. Strong LiveCodeBench for its size. Best "tiny but smart" option; good draft/reasoning helper.

### 5. GLM-Z1-32B-0414  (reasoning sibling of #2)
- **HF id:** `zai-org/GLM-Z1-32B-0414` (MIT). Also `GLM-Z1-9B-0414`, `GLM-Z1-Rumination-32B-0414`. — VERIFIED FACT
- **Architecture:** Dense 32B, reasoning (cold-start + RL on math/code/logic over GLM-4-32B-0414). — VERIFIED FACT
- **Benchmarks:** no separate coding table on the base card; community threads report GLM-4-32B ≥ GLM-Z1 for *coding* specifically, and "code not as good as QwQ-32B" (anecdotal, NOT primary). — no primary coding number found.
- **ESTIMATE:** same fit as #2 (~17–18 GB, fits; dense-32B slow decode + thinking tokens). Pick GLM-4-32B-0414 over this for coding unless you specifically want chain-of-thought.

### 6. DeepSeek-R1-Distill-Qwen-32B  (older reasoning distill)
- **HF id:** `deepseek-ai/DeepSeek-R1-Distill-Qwen-32B`. MLX: `mlx-community/DeepSeek-R1-Distill-Qwen-32B-MLX-4Bit`. GGUF everywhere. — VERIFIED FACT
- **Release:** Jan 2025. **Qwen2.5-32B** base, MIT (distill weights). — VERIFIED FACT
- **Benchmarks (DeepSeek-R1 paper/card):** LiveCodeBench **57.2**, Codeforces rating **1691**. — PUBLISHED-BENCHMARK (note third-party aggregators disagree wildly, e.g. LangDB "27.0"; trust the R1 paper). URL: https://arxiv.org/abs/2501.12948 (and `deepseek-ai/DeepSeek-R1` card)
- **ESTIMATE:** 4-bit ≈ 18 GB → **fits**; dense-32B reasoning → slow (~8–12 tok/s) + thinking overhead. Superseded for size-efficiency by R1-0528-Qwen3-8B and by GLM-4.7-Flash for throughput.

### 7. DeepSeek-R1-Distill-Qwen-14B
- **HF id:** `deepseek-ai/DeepSeek-R1-Distill-Qwen-14B` (MIT, Qwen2.5-14B base). — VERIFIED FACT
- **Benchmarks (R1 paper):** Codeforces rating **1481**; LiveCodeBench ~**53.1** (paper). — PUBLISHED-BENCHMARK (aggregators noisy). URL: https://arxiv.org/abs/2501.12948
- **ESTIMATE:** 4-bit ≈ 8 GB → **fits easily**, fast-ish (14B dense). Middle option; R1-0528-Qwen3-8B is newer/smarter per-GB.

### 8. CodeGeeX4-All-9B
- **HF id:** `zai-org/codegeex4-all-9b` (formerly `THUDM/codegeex4-all-9b`). GGUF: `QuantFactory/codegeex4-all-9b-GGUF`. — VERIFIED FACT
- **Release:** July 2024; continually trained on **GLM-4-9B**. — VERIFIED FACT
- **Architecture:** Dense 9B. **Context 128K.** — VERIFIED FACT
- **Benchmarks (official card table):** HumanEval **82.3**, MBPP **75.7**, NaturalCodeBench 40.4; BigCodeBench 48.9 complete / 40.4 instruct (card/aiwiki). — PUBLISHED-BENCHMARK. URL: https://huggingface.co/zai-org/codegeex4-all-9b
- **Features:** completion+generation, code interpreter, web search, function call, repo-level QA. License = custom "other" (source Apache-2.0; **weights custom — check for commercial terms**). transformers pinned 4.39–4.40.2 (old).
- **ESTIMATE:** 4-bit ≈ 5 GB → **fits easily**; fast. Good lightweight coder/autocomplete with long context, but 2024-era quality and a non-MIT weight license.

---

## NOT PRACTICAL ON 32GB (report-only)

| Model | HF id | Arch | Why it won't fit | Coding (primary) |
|---|---|---|---|---|
| **GLM-4.5-Air** | `zai-org/GLM-4.5-Air` | MoE **106B-A12B**, 128K, MIT, hybrid thinking | 4-bit ≈ 56 GB, 3-bit ≈ 44 GB, IQ2 ≈ 30–32 GB (no room for KV+OS). **Marginal only at extreme <=2-bit with tiny ctx — not recommended.** 12B active → would be fast *if* it fit. | aggregate 59.8/12-bench (primary chart, no per-bench SWE number in card text) — PUBLISHED-BENCHMARK (aggregate) https://huggingface.co/zai-org/GLM-4.5 |
| **GLM-4.6** | `zai-org/GLM-4.6` | MoE ~355/357B, 200K ctx, MIT | ~180GB @4-bit | SWE-bench Verified reported ~68 (secondary; not from a primary page in this pass) — NOT verified |
| **GLM-4.7** | `zai-org/GLM-4.7` | MoE ~355B, MIT | ~180GB @4-bit | — |
| **DeepSeek-V3.1** | `deepseek-ai/DeepSeek-V3.1` | MoE **685B** (37B active), hybrid, MIT code / DeepSeek model license | ~350GB @4-bit | — |
| **DeepSeek-V3.2** (and V3.2-Exp, V3.2-Speciale) | `deepseek-ai/DeepSeek-V3.2` | MoE **685B**, DeepSeek Sparse Attention (DSA), MIT | ~350GB @4-bit | SWE-bench Verified **70**, SWE-bench Pro 15.56, Terminal-Bench 2.0 **39.6** (official HF card) — PUBLISHED-BENCHMARK https://huggingface.co/deepseek-ai/DeepSeek-V3.2 ; release 2025-12-01, V3.2 integrates "thinking with tools" (V3.2-Speciale has NO tool-calling) |

Note: all the big MoEs are state-of-the-art coders but require many tens-to-hundreds of GB; not relevant to this machine even on SSD (you cannot mmap-stream a 4-bit 355–685B model into 32GB at usable speed on an exFAT/USB SSD ~1 GB/s — matches the user's own "quantize-to-fit beats expert-streaming" finding in memory).

---

## ENGINEERING ASSESSMENT (ESTIMATE) — fit + speed vs the Qwen3-30B-A3B baseline

**Clear fits, ranked by coding value on this box:**
1. **GLM-4.7-Flash (30B-A3B, MIT)** — *the headline result.* Same ~17GB footprint and same MoE 3B-active shape as the baseline → expect **~baseline throughput (~30–40 tok/s)** with **newer weights and higher published coding/agentic scores (SWE-bench 59.2, LCB 64.0, τ²-bench 79.5)** and first-class tool-calling + hybrid thinking. This is a true drop-in upgrade in the exact memory slot the user already uses. **Recommend as #1 to pull after this research.**
2. **DeepSeek-Coder-V2-Lite (16B-A2.4B)** — fastest decode of all (2.4B active), ~10GB, great for snappy/inline coding and as a draft model; 2024-era quality and non-MIT license are the tradeoffs.
3. **GLM-4-32B-0414 (dense, MIT)** — best non-reasoning, strong-tool-calling dense coder that fits; slower (dense 32B, ~8–13 tok/s) but deterministic.
4. **DeepSeek-R1-0528-Qwen3-8B (MIT)** — best smart-but-tiny reasoning coder (LCB 60.5), trivially fits with full context; reasoning tokens add latency.
5. Reasoning dense-32Bs (GLM-Z1-32B, R1-Distill-Qwen-32B) and mid distills (R1-Distill-14B) all fit but are either slower or older per-GB.

**MoE vs dense for decode speed on this machine (ESTIMATE):** the two MoEs here (GLM-4.7-Flash 3B-active, Coder-V2-Lite 2.4B-active) will feel like the baseline or faster; every dense 14–32B option will be noticeably slower because all parameters are active each token. So for an interactive coding agent, the MoE pair is the sweet spot.

**GLM-4.5-Air verdict (the one the user specifically asked to relate to the baseline):** at 106B-A12B it is **~3× the baseline's weight size**; it does **not** fit at any quality-preserving quant (4/3-bit = 44–56GB). Only sub-2-bit with tiny context would squeeze in, which wastes the 12B-active speed advantage and degrades a coding model badly — **not recommended on 32GB.** If the user wants "GLM-Air-like capability that fits," **GLM-4.7-Flash is the practical substitute** (newer generation, fits natively).

---

## Sources (every URL used)

DeepSeek — official / primary:
- https://api-docs.deepseek.com/news/news251201/ (DeepSeek-V3.2 release notes, 2025-12-01)
- https://api-docs.deepseek.com/news/news250929/ (DeepSeek-V3.2-Exp)
- https://api-docs.deepseek.com/news/news250821/ (DeepSeek-V3.1 release)
- https://huggingface.co/deepseek-ai/DeepSeek-V3.2 (V3.2 card: 685B, DSA, MIT, SWE-bench Verified 70, Terminal-Bench 2.0 39.6)
- https://github.com/deepseek-ai/DeepSeek-V3/blob/main/README_WEIGHTS.md (license split: MIT code / model license)
- https://github.com/deepseek-ai/DeepSeek-Coder-V2 (Coder-V2 / Lite benchmarks + license)
- https://arxiv.org/pdf/2406.11931 (DeepSeek-Coder-V2 paper)
- https://arxiv.org/abs/2501.12948 (DeepSeek-R1 paper — distill LiveCodeBench/Codeforces)
- https://huggingface.co/deepseek-ai/DeepSeek-R1-0528-Qwen3-8B ; mirror https://huggingface.co/ManuelZnnmc/DeepSeek-R1-0528/blob/main/README.md (LCB 60.5)
- https://huggingface.co/mlx-community/DeepSeek-R1-Distill-Qwen-32B-MLX-4Bit (MLX 4-bit)

GLM / Zhipu / Z.ai — official / primary:
- https://huggingface.co/zai-org/GLM-4.7-Flash (30B-A3B MoE, MIT, SWE-bench 59.2, LCB v6 64.0, τ²-bench 79.5, BrowseComp 42.8, glm47 tool parser)
- https://huggingface.co/zai-org/GLM-4-32B-0414 (dense 32B, MIT, 32K, SWE-bench 33.8/30.7/27.2, BFCL-v3 69.6; mentions GLM-Z1 variants)
- https://huggingface.co/zai-org/GLM-Z1-32B-0414/discussions (anecdotal coding comparisons only)
- https://huggingface.co/zai-org/GLM-4.5/blob/main/README.md (GLM-4.5 355B-A32B / GLM-4.5-Air 106B-A12B, 128K, MIT, aggregate 63.2 / 59.8, hybrid thinking)
- https://huggingface.co/zai-org/GLM-4.7 (full GLM-4.7)
- https://huggingface.co/zai-org/codegeex4-all-9b (CodeGeeX4-All-9B: dense 9B on GLM-4-9B, 128K, HumanEval 82.3, MBPP 75.7)

MLX / GGUF artifact repos (existence of quants):
- https://huggingface.co/lmstudio-community/GLM-4.7-Flash-MLX-4bit (+ 6bit/8bit siblings)
- https://huggingface.co/bartowski/zai-org_GLM-4.7-Flash-GGUF
- https://huggingface.co/unsloth/GLM-4.7-Flash-GGUF
- https://huggingface.co/mlx-community/GLM-4-32B-0414-4bit
- https://huggingface.co/mlx-community/GLM-4.7-4bit (full GLM-4.7, for reference)
- https://huggingface.co/lmstudio-community/DeepSeek-Coder-V2-Lite-Instruct-GGUF
- https://huggingface.co/QuantFactory/codegeex4-all-9b-GGUF
- https://huggingface.co/turboderp/GLM-4.5-Air-exl3 (shows how aggressively Air must be quantized — 2.5/3.0 bpw)

Secondary / context (not relied on for numbers):
- https://magazine.sebastianraschka.com/p/technical-deepseek
- https://www.deeplearning.ai/the-batch/zhipu-ai-z-ai-releases-open-weights-glm-4-5-models-that-perform-comparably-to-the-latest-from-claude-and-deepseek
- https://docs.nvidia.com/nemo/megatron-bridge/0.5.0/models/glm/glm45.html (GLM-4.5-Air layer/expert layout: 46 layers, 128 experts, top-8)
- https://osai-index.eu/model/codegeex (CodeGeeX4 release July 2024)
