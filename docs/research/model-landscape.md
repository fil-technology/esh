# esh Phase-A — Model Landscape Survey

**Target machine:** Apple M1 Pro, 32 GB unified memory, external ~2 TB SSD, macOS.
**Objective:** strongest *useful* intelligence that runs at usable speed, including models far larger than RAM via SSD-backed MoE expert streaming.
**Speed bands used throughout:** usable ≥2 tok/s · good ≥5 tok/s · excellent ≥10 tok/s (decode).
**Date compiled:** 2026-10-07. All numbers are from the cited sources; napkin estimates are explicitly labelled **[THEORETICAL]**.

---

## Machine budget (the numbers everything is measured against)

- **Unified memory:** 32 GB total. macOS + app overhead realistically leaves **~23–26 GB usable** for model weights + KV cache (willitrunai cites ~23 GB usable for weights on a 32 GB M1 Pro).
- **Memory bandwidth (the decode-speed ceiling):** M1 Pro = **~200 GB/s** (vs M2 Max ~400, M4 Max ~540). Decode tok/s for a dense model ≈ memory_bandwidth ÷ bytes-read-per-token, so M1 Pro runs roughly **half** the published M2 Max MLX numbers.
- **External SSD random read (streaming budget), ASSUMED:** Thunderbolt/USB4 NVMe enclosure ≈ 2.5–3 GB/s sequential, but **1–3 GB/s for the 0.5–2 MB semi-random reads** that expert streaming actually issues. I use **2 GB/s** as the central assumption and show 1 GB/s / 3 GB/s as the band.
- **Quant byte/param rules of thumb:** Q4/IQ4 ≈ 0.5 B/param · Q3 ≈ 0.42 · IQ2/Q2 ≈ 0.28 · MXFP4 ≈ 0.53 (4.25 bits).

---

## A. DENSE baselines (establish the quality/speed ceiling)

| Model | Params | Min quant that fits 32 GB (w/ usable ctx) | Quality tier | Est. M1 Pro decode tok/s | Interactive? |
|---|---|---|---|---|---|
| Qwen3-14B (dense) | 14B | Q4_K_M ≈ 8.5 GB, lots of ctx headroom | strong mid | **~17.7 tok/s** (measured, Q4) | Yes — comfortably |
| Qwen3-32B / Qwen2.5-32B | 32B | Q4 ≈ 18–19 GB fits; IQ3 for long ctx | strong | ~7–10 tok/s [THEORETICAL, bandwidth-scaled] | Yes, but sluggish |
| Llama-3.3-70B (dense) | 70B | **Does not fit** — Q4 ≈ 40 GB, IQ2 ≈ 23 GB marginal, degraded | high | ~2–4 tok/s at IQ2 w/ tiny ctx [THEORETICAL] | Barely / no |
| 100B+ dense (e.g. Mistral-Large-123B) | 123B | **No** at usable quality (IQ2 ≈ 35 GB > budget) | very high | n/a | No |

**Takeaway for A:** On a 32 GB M1 Pro the dense ceiling you can actually *use* is ~14B comfortably (interactive) and ~32B as the practical top (good-not-fast). 70B dense is a degraded-quant curiosity; 100B+ dense is out. **This is exactly why the MoE route matters** — it's the only way to get 70B-plus *quality* onto this machine at usable speed, because decode cost tracks *active* params, not total.

Reference measured anchors: Llama-3.1-8B Q5 ≈ 19 tok/s; Qwen3-14B Q4 = 17.7 tok/s (M1 Pro 32 GB). MLX is ~1.4–1.6× llama.cpp on dense 3–8B and up to ~3× on MoE.

---

## B. SPARSE / MoE (PRIMARY FOCUS)

Per-token decode cost and SSD-read cost both scale with **active** params and **expert granularity**, not total. The always-resident part = attention blocks + shared expert(s) + router + embeddings; routed experts are the cold, streamable mass.

### B.1 Master table

| Model (HF id) | Total | Active/tok | #experts | exp/tok | shared | Resident part (attn+shared+router+emb) | Resident @quant | Cold expert mass @quant | License |
|---|---|---|---|---|---|---|---|---|---|
| **Qwen3-Next-80B-A3B** `Qwen/Qwen3-Next-80B-A3B-Instruct` / `-Thinking`; MLX `mlx-community/Qwen3-Next-80B-A3B-Instruct-4bit` | 80B | **~3B (A3B)** | **512** + 1 shared | **10** | 1 | ~4B (hidden 2048, 48 layers, hybrid Gated-DeltaNet+Gated-Attn) | **~2 GB @Q4 / ~1.3 GB @IQ2** | Q4 ≈ 38 GB · IQ2 ≈ 21 GB | Apache-2.0 |
| **Qwen3-30B-A3B** `Qwen/Qwen3-30B-A3B` | 30.5B | **3.3B** | 128 | 8 | 0 | ~2–3B | ~2 GB @Q4 | Q4 ≈ 15 GB (whole model ≈ 17 GB) | Apache-2.0 |
| **gpt-oss-20b** `openai/gpt-oss-20b` | 20.9B | **3.6B** | 32 | 4 | 0 | small | ships MXFP4 | MXFP4 whole ≈ **11–12 GB** | Apache-2.0 |
| **gpt-oss-120b** `openai/gpt-oss-120b` | 116.8B | **5.1B** | 128 | 4 | 0 | ~small | — | MXFP4 whole ≈ **63 GB** (experts ~90%) | Apache-2.0 |
| **GLM-4.5-Air** `zai-org/GLM-4.5-Air` | 106B | **12B** | 128 (+shared) | 8 | 1 | ~first layer dense + attn | ~3–4 GB @IQ2 | IQ2 ≈ 26–28 GB · Q4 ≈ 55 GB | MIT |
| **Qwen3-235B-A22B** `Qwen/Qwen3-235B-A22B` | 235B | **22B** | 128 | 8 | 0 | large (100 layers, hidden 10240) | ~6 GB @IQ2 | IQ2 ≈ 60 GB | Apache-2.0 |
| **Llama-4-Scout** `meta-llama/Llama-4-Scout-17B-16E` | 109B | **17B** | 16 (+shared) | 1 | 1 | big (few huge experts) | ~5 GB | IQ2 ≈ 25 GB | Llama-4 community |
| **Llama-4-Maverick** `meta-llama/Llama-4-Maverick-17B-128E` | 400B | 17B | 128 | 1 | 1 | big | — | IQ2 ≈ 110 GB | Llama-4 community |
| **Mixtral-8x7B** `mistralai/Mixtral-8x7B-v0.1` | 47B | **13B** | 8 | 2 | 0 | ~coarse, 7B-scale experts | — | Q4 whole ≈ 26 GB | Apache-2.0 |
| **Mixtral-8x22B** `mistralai/Mixtral-8x22B-v0.1` | 141B | 39B | 8 | 2 | 0 | coarse | — | IQ2 ≈ 40 GB | Apache-2.0 |
| **DeepSeek-V3 / R1** `deepseek-ai/DeepSeek-V3` (& R1) | 671B | **37B** | 256 | 8 | 1 | MLA (compressed KV) | ~10 GB @IQ2 | IQ2 ≈ 175 GB | DeepSeek (MIT-ish for R1) |
| **Kimi-K2** `moonshotai/Kimi-K2-Instruct` | 1T | **32B** | 384 | 8 | — | 61 layers, hidden 7168 | — | IQ2 ≈ 260 GB | Modified-MIT |
| **MiniMax-M1** `MiniMaxAI/MiniMax-M1-80k` | 456B | **45.9B** | — | — | — | lightning-attn | — | IQ2 ≈ 120 GB | Apache-2.0 |
| **Granite-4.0-H-Small** `ibm-granite/granite-4.0-h-small` | 32B | **9B** | 72 | 10 | hybrid Mamba2 | 4 attn + 36 Mamba2 layers | ~2.5 GB @Q4 | Q4 whole ≈ 17 GB | Apache-2.0 |
| **Granite-4.0-H-Tiny** `ibm-granite/granite-4.0-h-tiny` | 7B | **1B** | fine-grained | — | hybrid | — | Q4 whole ≈ 4 GB | Apache-2.0 |

### B.2 Napkin estimates for the promising ones [THEORETICAL]

Formula: `SSD bytes/token = (routed-experts/token) × (per-expert bytes at quant)`, then `SSD-bound tok/s = SSD_GBps ÷ (uncached fraction × SSD bytes/token)`. Per-expert size derived from each model's expert FFN (SwiGLU = 3 matrices).

**★ Qwen3-Next-80B-A3B — the headline streaming candidate.**
- Per-expert ≈ 3.1M params (hidden 2048 × moe_intermediate 512 × 3 SwiGLU matrices). At Q4 ≈ **1.55 MB/expert**; at IQ2 ≈ **0.87 MB**.
- Routed loads/token = 10 × 48 layers = **480 expert-loads/token**.
- Full cold read/token: Q4 ≈ **744 MB**, IQ2 ≈ **418 MB** (shared expert is resident, excluded).
- **IQ2 fits ENTIRELY in RAM:** 21 GB experts + ~1.3 GB resident + KV ≈ **23 GB < 26 GB budget → zero streaming, decode is bandwidth-bound only.** This is the standout: an 80B-class brain with 3B active, fully resident at ~2-bit.
- **Q4 with partial streaming:** 38 GB experts, ~24 GB RAM cache holds ~63% → 37% streams = ~275 MB/token → at 2 GB/s ≈ **7.3 tok/s** SSD-bound (1 GB/s→3.6, 3 GB/s→11). Locality/LRU pushes higher.
- Measured MLX reality check (fully-resident on bigger RAM): 4-bit = ~42 tok/s on M2 Max, ~72 tok/s on M5 Pro. Bandwidth-scaled to M1 Pro ≈ **15–20 tok/s if it fit in RAM** → IQ2/IQ3 resident on M1 Pro should land **good-to-excellent**.

**Qwen3-30B-A3B — safest excellent pick.**
- Q4 whole ≈ 17 GB → **fully resident, no streaming.** 3.3B active, 128 experts/8.
- Decode: MoE active ≈ 3.3B → bandwidth-bound. [THEORETICAL] M1 Pro ≈ **18–30 tok/s** (MLX MoE speedup applies). **Excellent band, fits with room for 32k+ ctx.**

**gpt-oss-20b — fast reasoning, trivially fits.**
- MXFP4 ≈ 11–12 GB resident, 3.6B active, top-4/32. [THEORETICAL] M1 Pro ≈ **15–25 tok/s → excellent.** Native 4-bit means no quant-quality loss.

**gpt-oss-120b — the SSD-streaming stretch.**
- Per-expert ≈ 22.8M params (105B experts ÷ 128 ÷ 36). MXFP4 ≈ **12 MB/expert**.
- Loads/token = 4 × 36 = 144 → cold read ≈ **1.7 GB/token**.
- 63 GB total, ~24 GB RAM cache = 38% cached → 62% streams ≈ 1.05 GB/token → at 2 GB/s ≈ **1.9 tok/s** (1 GB/s→0.95, 3 GB/s→2.9). **Borderline-usable at best, cache-dependent.** Coarser granularity (big 22M experts, only 128) makes it worse to stream than Qwen3-Next.

**GLM-4.5-Air — strongest-that-nearly-fits.**
- IQ2 ≈ 26–28 GB → **marginal fit / light streaming.** 12B active is 4× Qwen3-Next's → ~4× the per-token read; at IQ2 decode is ~12B active → bandwidth-bound ~**4–7 tok/s** if resident. Good quality (coding-strong). Tight on 32 GB.

**Granite-4.0-H-Small — efficient hybrid.**
- Q4 ≈ 17 GB resident, 9B active, Mamba2-heavy (low KV growth, great for long ctx). [THEORETICAL] ≈ **8–14 tok/s.** Solid, enterprise-clean Apache-2.0, weaker raw intelligence than Qwen3-30B.

**Ruled out for this machine (active params and/or total too large):** Qwen3-235B-A22B (22B active → ~6 GB/token read, <1 tok/s), Llama-4 Scout/Maverick (17B active, coarse 1-of-16 experts stream badly), Mixtral-8x22B (39B active), DeepSeek-V3/R1 (37B active, 175 GB), Kimi-K2 (32B active, 260 GB), MiniMax-M1 (45.9B active). Mixtral-8x7B (13B active, 26 GB Q4) *technically* fits but is older/weaker than Qwen3-30B at similar footprint — dominated.

**Flag — promising for 32 GB + SSD streaming** (small resident + small active + fine-grained experts): **Qwen3-Next-80B-A3B (best), Qwen3-30B-A3B (fits outright), gpt-oss-20b (fits outright)**; gpt-oss-120b and GLM-4.5-Air as stretch/marginal.

---

## C. Architectures with OFFLOADABLE auxiliary params (ideal for SSD backing)

These store knowledge in large **key-value / lookup tables** where a token touches only top-k rows — so the table can live on SSD and only the retrieved rows are read, with far better random-access locality than streaming whole FFN experts.

- **Meta "Memory Layers at Scale"** (arXiv 2412.09764): trainable product-key K-V memory, demonstrated to **128B memory params** added with ~no extra FLOPs; a token retrieves a tiny top-k set. Beats dense models with 2× the compute. **Canonical offloadable-table architecture** — the memory bank is a natural SSD resident with top-k `pread`.
- **DeepMind PEER / "Mixture of a Million Experts"** (arXiv 2407.04153): product-key router over **>1,000,000 single-neuron experts**; retrieves k tiny experts per token. Extreme granularity ⇒ minimal bytes/token ⇒ the expert pool is the most SSD-friendly layout known.
- **ByteDance UltraMem** (arXiv 2411.12364): ultra-sparse large memory layer (up to **20M memory slots**), 2–6× faster inference and up to 83% cheaper than MoE by cutting memory-access volume per token. Designed specifically around the memory-access problem SSD streaming hits.
- **Plain large embedding / tied-embedding & output tables:** for big-vocab models (Kimi 160k vocab, Qwen 151k) the embedding matrix is hundreds of MB touched only at input/output — trivially memory-mappable from SSD, never needs a full sequential read.

**Status:** no strong *open-weight, ready-to-run* checkpoint of PEER/UltraMem/Memory-Layers exists yet (research-stage). They are the right *direction* for esh's SSD-backed thesis; today the practical embodiment of "offloadable mass touched top-k per token" is **fine-grained MoE (Qwen3-Next's 512 experts, gpt-oss' 128)**, which is why those rank first.

---

## Ranked shortlist — most promising to try FIRST on this exact machine

1. **Qwen3-30B-A3B** (`Qwen/Qwen3-30B-A3B`, MLX 4-bit) — fits fully in RAM at Q4 (~17 GB), 3.3B active, ~18–30 tok/s **excellent**; the low-risk quality/speed sweet spot and the baseline to beat.
2. **Qwen3-Next-80B-A3B** (`mlx-community/Qwen3-Next-80B-A3B-Instruct-4bit`; IQ2/IQ3 for full residency) — 80B-class intelligence, only 3B active, 512 fine-grained experts; **IQ2 fits entirely in 32 GB**, Q4 streams at ~7 tok/s [THEORETICAL]. The headline bet and the direct test of the SSD-streaming thesis.
3. **gpt-oss-20b** (`openai/gpt-oss-20b`, native MXFP4 ~12 GB) — fits trivially, 3.6B active, strong reasoning, ~15–25 tok/s **excellent**; best effort-to-value, zero quant loss.
4. **GLM-4.5-Air** (`zai-org/GLM-4.5-Air`, IQ2 ~26–28 GB) — strongest coding/agentic quality that *nearly* fits; marginal at 32 GB, ~4–7 tok/s [THEORETICAL]. Try once the streaming harness exists.
5. **Granite-4.0-H-Small** (`ibm-granite/granite-4.0-h-small`, Q4 ~17 GB) — hybrid Mamba2, 9B active, cheap long-context KV, clean Apache-2.0; ~8–14 tok/s. Good "efficient long-context" slot.
6. **gpt-oss-120b** (`openai/gpt-oss-120b`, MXFP4 ~63 GB, SSD-streamed) — the >>RAM stress test: 5.1B active but coarse 22M experts ⇒ ~1.7 GB/token read ⇒ **~1–2 tok/s** [THEORETICAL], cache-dependent. Worth a streaming benchmark precisely to measure the SSD ceiling in practice.

**One-line thesis:** decode cost follows *active* params and *expert granularity*, not total size — so the ranking is driven by (small active) × (many small experts) × (tiny resident core), which is exactly Qwen3-Next's and the gpt-oss/Qwen3-30B profile, not the big-active DeepSeek/Kimi/Llama-4 giants.

---

## Sources
- Qwen3-Next-80B-A3B: https://huggingface.co/docs/transformers/v4.57.1/en/model_doc/qwen3_next · https://huggingface.co/mlx-community/Qwen3-Next-80B-A3B-Instruct-4bit/blob/main/README.md · https://apxml.com/models/qwen3-next-80b-a3b · https://huggingface.co/Qwen/Qwen3-Next-80B-A3B-Instruct-GGUF
- Qwen3-235B-A22B: https://apxml.com/models/qwen3-235b-a22b · https://docs.nvidia.com/nemo/automodel/latest/model-coverage/llm/qwen/qwen3-moe.html
- Qwen3-30B-A3B: https://apxml.com/models/qwen3-30b-a3b · https://openrouter.ai/models/qwen/qwen3-30b-a3b
- DeepSeek-V3/R1: https://fireworks.ai/blog/deepseek-model-architecture · https://docs.nvidia.com/nemo/megatron-bridge/latest/models/deepseek/deepseek-v3.html · https://apxml.com/models/deepseek-v3
- Llama-4: https://huggingface.co/docs/transformers/main/model_doc/llama4 · https://www.gocodeo.com/post/llama-4-models-architecture-benchmarks-more
- GLM-4.5-Air: https://docs.nvidia.com/nemo/automodel/model-coverage/large-language-models/thudm/GLM-4.5-Air.md
- gpt-oss: https://arxiv.org/pdf/2508.10925 · https://inferencex.semianalysis.com/model/gptoss-120b
- Mixtral / Kimi K2: https://apxml.com/models/mixtral-8x22b-v0-1 · https://apxml.com/models/kimi-k2-base · https://canirun.ai/model/kimi-k2/
- MiniMax-M1 / Granite 4.0: https://openrouter.ai/models/minimax/minimax-m1 · https://www.ibm.com/new/announcements/ibm-granite-4-0-hyper-efficient-high-performance-hybrid-models · https://www.llmreference.com/model/granite-4.0-h-small
- Apple Silicon speeds: https://willitrunai.com/can-run/qwen-3-14b-on-m1-pro-32gb · https://willitrunai.com/de/can-run/llama-3.1-70b-on-m1-pro-32gb · https://omlx.ai/benchmarks/wjn65xp9 · https://machinelearning.apple.com/research/exploring-llms-mlx-m5 · https://llmcheck.net/models/qwen3-coder-next-on-m4-max/
- SSD/MoE offloading: https://arxiv.org/html/2601.17063v1 (FlashMoE) · https://arxiv.org/pdf/2508.06978 · https://github.com/ggml-org/llama.cpp/discussions/23324 · https://dev.to/anyesh/running-a-26b-moe-on-an-8-gb-jetson-by-streaming-experts-from-ssd-2jpf
- Offloadable memory architectures: https://arxiv.org/pdf/2412.09764 (Memory Layers at Scale) · https://arxiv.org/pdf/2407.04153 (PEER / Mixture of a Million Experts) · https://arxiv.org/abs/2411.12364v1 (UltraMem)
