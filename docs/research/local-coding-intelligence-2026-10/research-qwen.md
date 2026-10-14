# Qwen coding models for local use on M1 Pro / 32GB — state as of 2026-10-14

**Scope:** Qwen open-weight models with strong coding ability, runnable locally on a MacBook Pro M1 Pro, 32GB unified memory, weights on external SSD (measured ~1 GB/s, exFAT/USB), via MLX (4-bit/3-bit) or GGUF/llama.cpp (Q/IQ/K-quants).

**Baseline (user-measured, from memory):** Qwen3-30B-A3B (general, *not* coder) at MLX 4-bit = **~17.2 GB resident, ~37 tok/s** on this exact M1 Pro/32GB. All candidates below are related to this baseline.

**Label key used throughout:**
- **VERIFIED FACT** = read directly from an official HF model card or the official QwenLM GitHub README (primary).
- **PUBLISHED-BENCHMARK** = a number printed on the official model card / blog (vendor self-reported). Cited with URL. NOT my estimate.
- **ESTIMATE** = my engineering inference (memory fit, tok/s). Clearly my own.

> Caveat on benchmark numbers: card contents below were extracted via an automated page-reader. Treat the exact decimals as "from the card, verify on the card's own benchmark table before quoting externally." They are vendor self-reported in all cases (no third-party leaderboard confirmation was located). The Qwen3.8-27B numbers in particular are strikingly high and warrant a direct look at the card.

---

## 1. The current Qwen lineup (Oct 2026) — what actually exists

**VERIFIED FACT** (QwenLM GitHub README, Qwen HF org). Knowledge-cutoff note: everything after Jan 2026 below was confirmed live, not recalled.

| Family | Released | Models (HF `Qwen/…`) | Notes |
|---|---|---|---|
| Qwen3-Coder (dedicated coders) | 2025 → upd. Dec 2025 | `Qwen3-Coder-30B-A3B-Instruct`, `Qwen3-Coder-480B-A35B-Instruct` (+FP8) | Apache-2.0, non-thinking, strong tool-calling |
| **Qwen3-Coder-Next** (dedicated coder) | ~early Feb 2026 | `Qwen3-Coder-Next` (+ `-Base`, `-FP8`, `-GGUF`) | Apache-2.0, 80B-A3B hybrid MoE, non-thinking |
| Qwen3.5 (general, strong coding) | 2026-02-16 → 03-02 | `Qwen3.5-397B-A17B`, `-122B-A10B`, `-35B-A3B`, `-27B`, `-9B`, `-4B`, `-2B`, `-0.8B` | MoE (big) + dense (small). Apache-2.0 |
| Qwen3.6 (general+vision, strong coding) | 2026-04-16 / 04-22 | `Qwen3.6-35B-A3B` (MoE), `Qwen3.6-27B` (dense) | Apache-2.0, **thinking mode**, **vision encoder** |
| Qwen3.8 (general+vision, latest) | 2026-08-12 / 08-14 | `Qwen3.8-2.4T-A95B` (MoE, huge), `Qwen3.8-27B` (dense) | Apache-2.0, **thinking** (`reasoning_effort`), **vision encoder** |

Key points:
- **No `Qwen3.5-Coder` / `3.6-Coder` / `3.8-Coder` official model exists.** Ollama/community "qwen3.5-coder" repos are community repackages, not Alibaba releases. The only *dedicated* coders are the Qwen3-Coder line (30B-A3B, 480B-A35B) and **Qwen3-Coder-Next**.
- The 3.5/3.6/3.8 general models are explicitly positioned for agentic coding and ship the `qwen3_coder` tool-call parser.
- Qwen3.6 and Qwen3.8 are **multimodal** (vision encoder). For pure text/coding you use the text weights; vision needs a separate `mmproj` file in GGUF.
- `Qwen3-Next-80B-A3B` (2025-09-11) is the base architecture under Qwen3-Coder-Next. (This is the "bet" model in the user's own research memory.)

---

## 2. Per-model detail (coding-relevant, with fit focus)

### A. Qwen3-Coder-30B-A3B-Instruct  ← closest peer to the user's baseline
- **HF:** `Qwen/Qwen3-Coder-30B-A3B-Instruct` (+`-FP8`). Collection last updated Dec 31 2025. **VERIFIED FACT.**
- **Arch:** MoE, **30.5B total / 3.3B active**, 48 layers, 128 experts (8 active), GQA 32Q/4KV. **VERIFIED FACT.**
- **Context:** 262,144 native; up to **1M via YaRN**. **VERIFIED FACT.**
- **License:** **Apache-2.0** (commercial use OK). **VERIFIED FACT.**
- **Thinking:** non-thinking only (no `<think>`). Rec. sampling temp 0.7 / top_p 0.8 / top_k 20. **VERIFIED FACT.**
- **Tool-calling:** Yes — "specially designed function call format," OpenAI-compatible; Qwen Code + Cline named. `qwen3_coder` parser. **VERIFIED FACT.**
- **Coding benchmarks:** **No primary-source number found.** The model card prints no values; the Qwen3-Coder launch blog covers only the 480B. → *no primary source found* for SWE-bench/LCB on the 30B-A3B specifically.
- **Quants that exist:** `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` (Apache-2.0), `lmstudio-community/…-MLX-4bit`, `…-MLX-5bit`; GGUF widely published. **VERIFIED FACT (repos exist).**
- **Swift/TS commentary:** unknown (no primary commentary found).

### B. Qwen3.6-35B-A3B  ← best in-budget quality/speed balance
- **HF:** `Qwen/Qwen3.6-35B-A3B`. Released ~Apr 2026. **VERIFIED FACT.**
- **Arch:** MoE (hybrid Gated-DeltaNet + Gated-Attention), **35B total / 3B active**, 40 layers, 256 experts (8 routed + 1 shared), "Causal LM with Vision Encoder." **VERIFIED FACT.**
- **Context:** 262,144 native; up to ~1.01M via YaRN. **VERIFIED FACT.**
- **License:** **Apache-2.0.** **VERIFIED FACT.**
- **Thinking:** thinking on by default, `enable_thinking:false` to disable; `preserve_thinking`. **VERIFIED FACT.**
- **Tool-calling:** Yes; `qwen3_coder` parser in SGLang/vLLM; Qwen-Agent/Qwen Code. **VERIFIED FACT.**
- **Coding benchmarks (PUBLISHED-BENCHMARK, card):** SWE-bench Verified **73.4**; SWE-bench Multilingual **67.2**; SWE-bench Pro **49.5**; Terminal-Bench 2.0 **51.5**; LiveCodeBench v6 **80.4**. Aider/HumanEval not reported. Source: HF card.
- **Quants that exist:** `mlx-community/Qwen3.6-35B-A3B-4bit-DWQ`, `…-OptiQ-4bit`, `…-mxfp4`; `lmstudio-community/Qwen3.6-35B-A3B-MLX-4bit`; GGUF `unsloth/Qwen3.6-35B-A3B-GGUF` (UD-Q4_K_XL ~21 GB, UD-Q3_K_XL ~17 GB), `AtomicChat/…-GGUF` (Q4_K_M ~21.2 GB). Also a community coder finetune `mlx-community/Qwopus3.6-35B-A3B-Coder-4bit`. **VERIFIED FACT (repos exist); sizes are repo-listed.**
- **Swift/TS commentary:** unknown.

### C. Qwen3.8-27B  ← newest, highest benchmarks, but DENSE
- **HF:** `Qwen/Qwen3.8-27B`. Released ~Aug 13 2026. **VERIFIED FACT.**
- **Arch:** **Dense 27B** (Hub lists ~28B), 64 layers, hybrid Gated-DeltaNet/Gated-Attention + FFN, vision encoder. **VERIFIED FACT.** → dense = **all params active per token**.
- **Context:** 262,144 native; up to 1M via YaRN. **VERIFIED FACT.**
- **License:** **Apache-2.0.** **VERIFIED FACT.**
- **Thinking:** on by default; `reasoning_effort` xhigh(default)/medium/low; `enable_thinking:false`. **VERIFIED FACT.**
- **Tool-calling:** agent-harness compatible; built-in tools only in hosted Qwen Cloud; open-weights tool-call format not documented on the card. **VERIFIED FACT.**
- **Coding benchmarks (PUBLISHED-BENCHMARK, card — numbers look very high, verify directly):** Terminal-Bench 2.1 (Terminus) **73.0**; SWE-bench Pro **61.7**; QwenSWEBench **79.0**; LiveCodeBench v6 **90.3**; NL2Repo-Bench **42.3**; DeepSWE 1.1 **42.2**; (agentic) OSWorld-Verified **84.3**, WebArena **64.8**. SWE-bench Verified not reported. Source: HF card.
- **Quants that exist:** `mlx-community/Qwen3.8-27B-4bit`, `mlx-community/qwen3.8-27b-mtp-4bit` (multi-token-prediction — speeds decode), `lmstudio-community/Qwen3.8-27B-MLX-4bit`; GGUF `unsloth/Qwen3.8-27B-GGUF` (1-bit ~6 GB up to BF16 ~54.7 GB; Q4 ~14–17 GB). **VERIFIED FACT (repos exist).**
- **Swift/TS commentary:** unknown.

### D. Qwen3-Coder-Next (80B-A3B)  ← best agentic coder, does NOT fit 32GB at usable quant
- **HF:** `Qwen/Qwen3-Coder-Next` (+`-Base`/`-FP8`/`-GGUF`). Announced ~Feb 3 2026. Tech report arXiv 2603.00729 (as cited on card). **VERIFIED FACT.**
- **Arch:** hybrid MoE, **80B total (79B non-embed) / 3B active**, 48 layers, 512 experts (10 active + 1 shared), Gated Attention (16Q/2KV, head 256) + Gated DeltaNet. Base = Qwen3-Next-80B-A3B-Base. **VERIFIED FACT.**
- **Context:** 262,144 native (card suggests dropping to 32,768 on OOM). **VERIFIED FACT.**
- **License:** **Apache-2.0.** **VERIFIED FACT.**
- **Thinking:** non-thinking only. Rec. sampling temp 1.0 / top_p 0.95 / top_k 40. Needs sglang≥0.5.8 or vllm≥0.15.0. **VERIFIED FACT.**
- **Tool-calling:** Strong — "excels in tool calling," handles complex tool usage + recovery from execution failures; Claude Code / Qwen Code / Qoder / Kilo / Trae / Cline; `--tool-call-parser qwen3_coder`. **VERIFIED FACT.**
- **Coding benchmarks (PUBLISHED-BENCHMARK, card):** SWE-bench Verified **70.6**; SWE-bench Pro **44.3**; Terminal-Bench 2.0 **36.2**. Blog says agentic performance "comparable to Claude Sonnet." Source: HF card.
- **Quants that exist:** Official `Qwen/Qwen3-Coder-Next-GGUF`: **smallest is Q4_K_M = 48.4 GB** (then Q5_0 55, Q5_K_M 56.7, Q6_K 65.5, Q8_0 84.8, F16 159). **No official IQ2/IQ3/Q2_K/Q3_K.** Community MLX 4-bit: `AutomatosX/AX-Qwen3-Coder-Next-MLX-4bit` (+OptiQ); AWQ-4bit (`cyankiwi`, `bullpoint`) are for vLLM/SGLang, not Apple Silicon. **VERIFIED FACT.**
- **Swift/TS commentary:** unknown.

### E. Other, briefly
- **Qwen3.5-35B-A3B** (Feb 2026): MoE 35B/3B, Apache-2.0 — superseded by the stronger Qwen3.6-35B-A3B; same fit class. Prefer 3.6.
- **Qwen3.5/3.6/3.8-27B dense**, **Qwen3.5-9B / -4B dense**: fit easily but 9B/4B are materially weaker coders; the 27B dense models share Qwen3.8-27B's "fits but slow (dense)" profile. Fast small-model fallback only.
- **Qwen3-Coder-480B-A35B** and **Qwen3.8-2.4T-A95B**: far beyond 32GB. Not candidates. (480B: SWE-bench Verified SOTA-among-open claimed, no number on blog.)

---

## 3. ENGINEERING ASSESSMENT — fit in 32GB (ESTIMATE, clearly my own)

Memory model (ESTIMATE): 32GB total − ~7GB macOS/runtime/wired overhead ≈ **~24–25GB usable** for weights + KV cache + activation scratch. KV cache at these ctx lengths is modest for these archs (grouped/hybrid attention, 2–4 KV heads) — roughly **~0.5–2 GB for 8k–32k** tokens (ESTIMATE). So the weight budget is the binding constraint; keep weights ≲ ~21–22GB to leave comfortable KV + headroom.

Reference point: baseline Qwen3-30B-A3B 4-bit = 17.2GB resident, 37 tok/s (measured by user).

| Model | Quant | Weights (approx) | Fits 32GB @ 8k–32k? | MoE/dense (active) | Est. decode vs 37 tok/s baseline |
|---|---|---|---|---|---|
| Qwen3-Coder-30B-A3B | MLX 4-bit | ~17 GB | **Yes, comfortable** | MoE (3.3B) | ~same, ~35–40 tok/s (ESTIMATE) |
| Qwen3-Coder-30B-A3B | MLX/GGUF 3-bit | ~13 GB | Yes, lots of headroom | MoE (3.3B) | ~same or faster (ESTIMATE) |
| Qwen3.6-35B-A3B | MLX 4-bit / GGUF Q4 | ~20–21 GB | **Yes, tighter** (watch KV at 32k) | MoE (3B) | ~30–37 tok/s (ESTIMATE) |
| Qwen3.6-35B-A3B | GGUF UD-Q3_K_XL | ~17 GB | Yes, comfortable | MoE (3B) | ~30–37 tok/s (ESTIMATE) |
| Qwen3.8-27B (dense) | MLX 4-bit / GGUF Q4 | ~15–17 GB | Yes on memory | **Dense (27B active)** | **much slower, ~8–15 tok/s (ESTIMATE)** |
| Qwen3.8-27B-mtp | MLX 4-bit (MTP) | ~15–17 GB | Yes on memory | Dense + MTP | faster than plain dense, still < MoE (ESTIMATE) |
| Qwen3-Coder-Next 80B-A3B | 4-bit (~40–45 GB) | ~40–45 GB | **No — does not fit** | MoE (3B) | n/a |
| Qwen3-Coder-Next 80B-A3B | hypothetical ~2-bit (~22–26 GB) | ~22–26 GB | Marginal, **no official artifact**; 2-bit degrades coding; SSD-resident on ~1 GB/s exFAT is the known bottleneck | MoE (3B) | would be fast IF resident (ESTIMATE) |

**MoE vs dense flag (ESTIMATE):** 30B-A3B coder, 35B-A3B (3.5/3.6), and Coder-Next are all **MoE with ~3B active → fast decode** (baseline-like). The **27B models (3.5/3.6/3.8) are dense → every token pays the full 27B**, so expect roughly 2–4× slower decode than the baseline on this M1 Pro, despite similar RAM use. The 3-bit lane buys headroom on the 35B-A3B with mild quality loss.

**Why Coder-Next (80B-A3B) is the trap here (ESTIMATE, consistent with user's own research memory):** only 3B active means it *would* decode fast if resident, but at any honest quant it is 40GB+ (official floor is Q4_K_M 48.4GB), overflowing 32GB. Pushing to ~2-bit has no published artifact and both (a) hurts coding accuracy and (b) forces expert spill to the ~1 GB/s external SSD — the measured ceiling that already killed expert-streaming in the user's prior analysis. Not recommended on 32GB.

---

## 4. Top candidates (fit class)

1. **Qwen3-Coder-30B-A3B-Instruct, MLX 4-bit** — *Best drop-in.* Same footprint/speed as the user's baseline (~17GB, ~37 tok/s), but a dedicated coder with first-class tool-calling. Apache-2.0. **FIT: comfortable.** Weakness: no primary coding benchmark number published; non-thinking.
2. **Qwen3.6-35B-A3B, MLX 4-bit (or GGUF UD-Q3_K_XL for headroom)** — *Best quality that still fits.* MoE 3B-active so baseline-like speed, but newer and stronger (SWE-bench Verified 73.4 / LiveCodeBench v6 80.4, card). Apache-2.0, optional thinking. **FIT: comfortable→tight at 4-bit; use 3-bit for 32k ctx.**
3. **Qwen3.8-27B, MLX 4-bit (prefer the -mtp build)** — *Highest benchmarks, but dense.* Fits memory easily (~15–17GB) with the strongest card numbers (LiveCodeBench v6 90.3, Terminal-Bench 2.1 73.0 — verify on card), yet dense 27B means notably slower decode than the baseline. **FIT: memory yes, speed the concern.**
4. **Qwen3-Coder-Next 80B-A3B** — *Aspirational only.* The strongest agentic coder (SWE-bench Verified 70.6; Claude-Sonnet-class agentic), but **does not fit 32GB** at any published quant (official GGUF floor 48.4GB). Revisit only with more RAM. **FIT: no.**

---

## Sources
- Qwen3-Coder-Next card: https://huggingface.co/Qwen/Qwen3-Coder-Next
- Qwen3-Coder-Next GGUF (official, sizes): https://huggingface.co/Qwen/Qwen3-Coder-Next-GGUF
- Qwen3-Coder-30B-A3B-Instruct card: https://huggingface.co/Qwen/Qwen3-Coder-30B-A3B-Instruct
- Qwen3-Coder GitHub (variant list): https://github.com/QwenLM/Qwen3-Coder
- Qwen3-Coder launch blog (480B): https://qwenlm.github.io/blog/qwen3-coder/
- Qwen3.6-35B-A3B card: https://huggingface.co/Qwen/Qwen3.6-35B-A3B
- Qwen3.8-27B card: https://huggingface.co/Qwen/Qwen3.8-27B
- QwenLM current lineup README (Qwen3.5/3.6/3.8): https://github.com/QwenLM/Qwen3.8
- MLX 4-bit coder (30B-A3B): https://huggingface.co/mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit
- LM Studio MLX 4-bit (30B-A3B): https://huggingface.co/lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-4bit
- MLX 4-bit DWQ (3.6-35B-A3B): https://huggingface.co/mlx-community/Qwen3.6-35B-A3B-4bit-DWQ
- MLX OptiQ-4bit (3.6-35B-A3B): https://huggingface.co/mlx-community/Qwen3.6-35B-A3B-OptiQ-4bit
- GGUF (3.6-35B-A3B, community, sizes): https://huggingface.co/AtomicChat/Qwen3.6-35B-A3B-GGUF
- Community coder finetune (3.6): https://huggingface.co/mlx-community/Qwopus3.6-35B-A3B-Coder-4bit
- MLX 4-bit (3.8-27B): https://huggingface.co/mlx-community/Qwen3.8-27B-4bit
- MLX MTP 4-bit (3.8-27B): https://huggingface.co/mlx-community/qwen3.8-27b-mtp-4bit
- mlx-community Qwen3.8 collection: https://huggingface.co/collections/mlx-community/qwen38
- MLX 4-bit (Coder-Next, community): https://huggingface.co/AutomatosX/AX-Qwen3-Coder-Next-MLX-4bit
- Wikipedia Qwen (timeline cross-check): https://en.wikipedia.org/wiki/Qwen
