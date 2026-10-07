# Strata runtime — technical analysis (Phase‑A deep dive)

**Target:** feasibility of SSD‑backed MoE expert streaming on Apple M1 Pro (32 GB unified memory, ~2 TB external SSD, macOS/Metal), using the **Strata** engine as the reference design.

**Repo analyzed:** `https://github.com/mach10x/strata` (MIT, default branch `main`, ~14 MB, 73★, last push 2026‑10‑07). A large, real C++17/CUDA engine (≈2 M bytes of `src/`), *not* the arXiv paper "Stratum: … 3D‑Stackable DRAM" (2510.05245), which is an unrelated hardware‑codesign paper. There is also a fork `eddoursul/Strata` (referenced for Unsloth Q4 support).

**Model it serves:** `Qwen3.8-Flash-Next` — a hybrid‑attention MoE. Confirmed geometry from `include/strata/core/layout.hpp` (`ModelGeometry`) [FROM-CODE]: `n_embd=2560`, `n_layers=48`, **512 experts/layer, top‑10 routed**, expert FF width `n_ff=640`, shared expert + gated residual (`hc=4` hyper‑connections) on every layer. Every 4th layer (3,7,…,47 → **12 layers**) is full QSA attention; the other **36** are GDN/DeltaNet linear‑attention mixers. Total routed experts = `48×512 = 24,576`. One ships‑with MTP (multi‑token‑prediction) draft layer.

**Labeling:** every claim is tagged `[FROM-DOCS]` (README/docs/*.md), `[FROM-CODE]` (headers/source), or `[INFERRED]` (my synthesis/skeptical reading). File/line citations are to the paths listed in **Sources**.

> **Skeptic's note up front.** The code comments are unusually candid and self‑critical ("the number the objective depends on", "measured before it is used", "this is the failure this project keeps paying for"). I treat measured numbers in comments as *the authors' own measurements on one reference box* (RTX 5070 12 GB / Ryzen 5 7600 / 64 GB DDR5), **not** independently verified. Several headline numbers are in‑sample or extrapolated and the docs say so. I could not run the engine or read the full 424 KB `src/program/generate.cpp` or 104 KB `layer.cpp`; conclusions about the generation loop come from headers + docs and are flagged.

---

## 1. Division of model state across GPU / RAM / SSD

Three explicit tiers (`docs/HOW_IT_WORKS.md`, `docs/DETAILS.md#how-it-works`, `include/strata/core/*`). [FROM-DOCS]+[FROM-CODE]

### MUST stay GPU‑resident (VRAM), per token, for every token
From `docs/DETAILS.md#how-it-works` and `weights.hpp`/`layout.hpp`: attention (QSA) + DeltaNet/GDN mixer weights, the gated‑residual/hyper‑connection weights, the **routers**, the **shared experts**, the **output head**, the **MTP draft layer**, and the KV cache (or at least its resident window). These are the "dense" weights. [FROM-DOCS]
- Dense weight arena ≈ **4.52 GiB in engine form** (`weights.hpp` comment: `4.067 GiB dense + 0.444 GiB embd + 10.88 MiB widened scales`). BF16 pack tensors are re‑rounded to 16‑bit; 90 quantized tensors carry fp16 scales widened to f32 in VRAM. [FROM-CODE]
- MTP draft layer ≈ **0.9 GB VRAM**; its 512 experts (708 MB) are fully VRAM‑resident (`mtp.hpp`: "all 512 routed experts live in VRAM (708 MB)"). [FROM-CODE]
- These dense parts are *not* disk‑backed in normal operation; they are the fixed VRAM cost before the expert cache.

### MAY be disk/RAM‑backed and streamed — the routed experts
The 24,576 routed experts are the streamable mass. They live in a 3‑level hierarchy:
- **GPU expert cache** (`expert_cache.hpp`): fills the *rest* of VRAM with the most‑used experts. Each slot holds one expert blob. On a 12 GB card the cache holds "a few thousand" experts; docs: **~700 experts per extra GB of VRAM** [FROM-DOCS]. Example from `expert_cache.hpp`: 4,105 slots ≈ 5,413 MiB on a card with ~6.4 GiB free [FROM-CODE]. The cache is profile‑filled + adaptive (see §3).
- **RAM**: the default is **all 24,576 experts pinned in host RAM** (`pinned.hpp`: 33.97 GB arena, page‑locked) [FROM-CODE]. The CPU computes the experts the GPU doesn't hold, *in place* in RAM.
- **SSD**: two things live here. (a) The **PLE / per‑layer‑token‑embedding table** — 28.8 GB, always SSD‑resident, never RAM‑cached (details §5/§2). (b) In **low‑RAM modes**, part or all of the expert set stays on disk (`experts.bin` mmap or GGUF‑in‑place) and is read on demand through the OS file cache.

### Quantitative split of the expert mass (Q2_0, the fast model) [FROM-CODE]+[FROM-DOCS]
- One expert blob = **1,382,400 B** (`cpu/expert.hpp`: `BLOB = 3·(H·FF·BB/QK)`, H=2560, FF=640, Q2_0 18 B/64 weights). `experts.bin` = **33,973,862,400 B** = exactly `48×512` blobs, index = `layer*512 + expert`, no padding (`expert_source.hpp` `FileExpertSource`). [FROM-CODE]
- So the division is: **~4.5 GiB dense (must be VRAM) + ~0.9 GiB MTP (VRAM) + 34 GiB experts (VRAM‑cache ∪ RAM ∪ SSD) + 28.8 GB PLE (SSD only)**. On the 12 GB reference card the expert cache is ~5–6 GiB (≈4,000 experts, h≈0.64), RAM holds all 34 GiB, SSD holds the 28.8 GB PLE. [INFERRED from the above]

### What is forced where, succinctly
| Tensor class | Must be VRAM | May be RAM | May be SSD |
|---|---|---|---|
| Attention/GDN/gated‑residual/router/shared‑expert/head/MTP | **yes** | no | no |
| KV cache | resident window (`--kv-resident`, default 32768) | tail streams from RAM ≥64K | no (unless low‑RAM keeps it in VRAM) |
| Routed experts (hot) | expert‑cache slots | — | — |
| Routed experts (cold) | — | pinned arena (default) | mmap/GGUF (low‑RAM) or `--resident-budget` overflow |
| PLE table (28.8 GB) | no | no (by design) | **yes, always** |

---

## 2. Per‑token access and bandwidth demand

Per decoded token the engine touches, in order (`expert_cache.hpp`, `pinned.hpp`, `ngram.hpp`): [FROM-CODE]+[FROM-DOCS]

1. **Dense forward over 48 layers on the GPU** — attention/GDN/router/shared‑expert/head. VRAM‑bandwidth bound; this is what the GPU is "always doing per word."
2. **PLE row gather from SSD** — 16 rows/token × 90 B (IQ4_NL) = **1,440 B/token**, scattered across the 28.8 GB table. `ngram.hpp`: "0.5 MB/s, which is latency and not bandwidth" — the cost is 16 random 4 KiB reads, measured **2.10–2.61 ms/token** via mmap page‑faults, dropped by batched prefetch. This is a **random small‑block, latency‑bound** workload, not bandwidth. [FROM-CODE]
3. **Routed experts** — `48 layers × 10 = 480` expert activations/token = **663.6 MB of expert weights per token** (`pinned.hpp`, `expert_cache.hpp`). This is *the* dominant term. Of it:
   - the fraction resident in the GPU cache (`h`) is computed on‑GPU and costs ~VRAM bandwidth;
   - `(1−h) × 663.6 MB` is the **miss stream**. By default those bytes are read from the **pinned RAM arena at ~40–44 GB/s** and computed by the CPU (AVX‑512). Measured: **663.6 MB ÷ ~40 GB/s = 16.2 ms** of CPU work on a ~53 ms token, and the pipeline hides only **1.055 ms of 19.035** — i.e. **the CPU expert path is ~96% exposed** because the residual chain is strictly serial (`expert_cache.hpp`). [FROM-CODE] This is the engine's single largest cost and the reason the whole architecture exists.
4. **KV cache** — read every token; from 64K context the hot window stays in VRAM and the tail streams from RAM‑mapped pinned memory over PCIe (`kv_stream.hpp`). Costs ~13.7 KB RAM/token (1.7 GB at 128K) [FROM-DOCS].

**Bandwidth budget, reference box (per token):** PLE ≈ 1.4 KB (latency‑bound), experts ≈ 663.6 MB (the whole game), KV ≈ tens of KB. **The design target is to minimize the expert miss stream**, since RAM at ~40 GB/s turns 663.6 MB into 16 ms if nothing is cached. GPU cache at h≈0.64 removes ~⅔ of it; PCIe miss‑offload removes more (§4). [INFERRED from code+docs]

**SSD‑as‑expert‑store math (relevant to Apple):** if experts come from SSD instead of RAM (low‑RAM/`--mmap-experts`), the miss stream is `(1−h)×663.6 MB/token` off NVMe. At, say, 5 GB/s sequential that is ~130 ms/token at h=0 — which is exactly why the docs report Unsloth UD‑Q4 (72 GiB experts, mostly SSD) runs at only **7–8.5 tok/s** vs 50–90 tok/s fully cached. [INFERRED from `docs/DETAILS.md` UD‑Q4 numbers]

---

## 3. Expert selection, hotness tracking, hot/cold execution

### How experts are chosen
`router_top10.hpp` [FROM-CODE]: per token, a BF16 GEMV produces `(n_tokens, 512)` logits (separate kernel), then `router_top10` does **softmax over all 512 experts → stable descending top‑10 (ties by index) → renormalize with ggml's 2⁻¹⁴ clamp**. Router weights are applied **once**, on the GPU, in `moe_combine` (`src/core/layer.cpp:479`), summing `w[i]·part[i]`. A hard contract warning in `expert_source.hpp`: the pool must **not** re‑apply the router weight (it is a diagnostic field only), or the weight compounds over 48 layers into a plausible‑but‑wrong token. [FROM-CODE]

### How "hotness" is tracked — two mechanisms
1. **Static offline profile** (`tools/make_profile.py`, `data/expert-profile.bin`, read by `read_expert_profile` in `expert_cache.hpp`). `STRP` file: all 24,576 `(layer,expert)` pairs ranked by **descending routing frequency** over a trace (built from `--dump-routing`). `--expert-cache auto` fills slots in profile order. Measured transfer: in‑sample `h=0.6573`, honest 10‑fold leave‑one‑out **0.6447 [0.611, 0.675]**; naive compulsory‑miss (fill with first‑seen) only 0.4864. A Coder‑specific profile ships (`expert-profile-coder.bin`), reporting 72% GPU hit on a 12 GB card. [FROM-CODE]+[FROM-DOCS]
2. **Adaptive/decayed online counts** (`ExpertDispatch::usage` in `expert_source.hpp`: "decayed routing counts per (layer,expert) during decode"). Between decode rounds the driver **swaps the most‑routed missing experts into VRAM** (`--adapt-every`, `--adapt-swaps`). Docs: "it keeps learning which ones those are while you use it." Swaps are the reason sampled output isn't run‑to‑run reproducible unless `--adapt-every 100000` (static residency). [FROM-CODE]+[FROM-DOCS]

**Per‑layer admission (important correctness fix, `expert_cache.hpp` R4.2g):** a *global* arrival‑order slot counter catastrophically fills the whole cache from ~26 layers of **position 0** (measured hit 2.97%). The fix: layer `l` may only use slots `[l·q,(l+1)·q)`. `Memory/cache_allocation.py`: 8 slots/layer → 21.4%, 64/layer → 70.4%. **The cache never evicts** (eviction policy deliberately deferred as "a measured question"); the adaptive tier does movement via explicit swaps instead. [FROM-CODE]

### Hot vs cold execution — the three‑way split
Because held‑out `h_layer = 0.0456` (only 4.6% of (layer,token) pairs have *all ten* experts resident, `expert_cache.hpp`), it cannot be a per‑layer grouped kernel. The split is **per router index within a layer** (`expert_source.hpp` R4.2c): [FROM-CODE]
- **Hot (resident) experts → GPU** via grouped "hit" kernels (`moe_hit_grouped`), launched after the misses are staged and before `post[l]`. CPU zeroes those rows; GPU writes them at the router index `moe_combine` expects.
- **Cold (missing) experts → CPU** AVX‑512 (`s2_expert_vnni*`), computed *in place* on the RAM arena, concurrently with the GPU hits.
- **A PCIe share of the misses → GPU over PCIe** (`--pcie-frac`, `GpuPlanSink`): rather than the CPU doing all misses, a configurable fraction of distinct missed experts is DMA‑copied (or read via mapped device alias) to the GPU and computed there — balancing a fast PCIe/slow‑CPU box against a laptop (`--calibrate` tunes it). [FROM-CODE]

### Copied or computed in place?
Both, deliberately. Experts the GPU cache already holds are **computed in place in VRAM** (no copy). Misses the CPU handles are **computed in place in the pinned RAM arena** (no copy — the whole point of `ArenaExpertSource`/pinned.hpp). Only the PCIe‑offloaded misses and cache *fills/swaps* are copied (DMA from pinned host → VRAM slot). A key activation‑parity subtlety (`expert_source.hpp` R4.2h): GPU hits use fp16 `block_q8_0` scale while CPU misses use fp32 `ActQ::scale`; feeding the CPU's fp32 scales to the GPU path is required or the cache changes the token (4.76e‑4 relative error). [FROM-CODE]

---

## 4. CPU/GPU overlap, expert prefetch, SSD access patterns

### Overlap model [FROM-CODE]+[FROM-DOCS]
- The GPU runs a layer's attention/dense work and its resident‑expert "hit" kernels **while the CPU computes that layer's missing experts** — "at the same time as the graphics card, so neither waits" (`HOW_IT_WORKS`). Implemented via a loop‑owned CUDA stream; the hit kernels are stream‑ordered after the miss staging and before `post[l]`.
- The engine is honest that overlap is fragile: `ExpertDispatch` R4.2d records a `hit_done` event to measure whether enqueued GPU hit work actually *began* before `pool()` returned ("the hit path is 0.91 ms slower and the only explanation left is that it never overlaps" — a lazy‑submission driver quirk seen 3×). `hit_poke` is an A/B fix (enter the driver once to kick the GPU). This is a real, measured risk, not theory. [FROM-CODE]
- Separate helper **CUDA devices** can serve experts (`remote_experts.hpp`: a static profile‑filled tier on CUDA1..3, results returned through pinned CPU rows, optional zero‑copy). Multi‑GPU layer split also exists (`--gpus`, `docs/MULTI_GPU.md`). [FROM-CODE]+[FROM-DOCS]

### Expert prefetch — routing‑aware lookahead
`RouterLookahead` (`expert_source.hpp`) [FROM-CODE]: when the CPU pool starts layer `l`, a worker thread applies **layer l+1's router (BF16 host copy) to layer l's MoE input** (the residual changes little layer‑to‑layer), takes each token's top‑10, drops experts the GPU cache or RAM copy already holds, and asks the source to `warm()` the rest — i.e. start the OS reading those SSD pages **now, in the background**, so they land while layer `l` computes. Prediction only warms pages; it never changes which experts are computed (`STRATA_LOOKAHEAD=0` disables). This is the key trick that makes GGUF‑in‑place / `--resident-budget` SSD modes tolerable. `warmed_hits()` counts how many file reads were pre‑warmed. [FROM-CODE]

During **prefill**, the next layer's experts are streamed to the GPU over PCIe while the current layer's attention runs (`docs/DETAILS.md` "Faster prompts"). [FROM-DOCS]

### SSD access patterns
- **PLE table (28.8 GB):** pure **random, small‑block, latency‑bound** — 16 rows/token at 90 B each, scattered over the whole table. Default I/O is `DirectFile` **unbuffered O_DIRECT/`FILE_FLAG_NO_BUFFERING`+OVERLAPPED/IOCP**, 4 KiB‑aligned, from a small thread pool (`STRATA_IO_THREADS`: default **4 Windows / 16 Linux**), up to 64 in flight (decode needs 16) (`direct_file.hpp`, `ngram.hpp` `PleIoOptions`). The table is **deliberately never cached in RAM** — a live mmap on the same file serializes the direct reads (311→1,575 µs/token regression). A bounded ~95 MB row cache and an optional keep‑alive (keep the SSD awake) exist. mmap is kept only as an A/B arm. [FROM-CODE]
- **Expert set from SSD (low‑RAM):** read per‑expert through the OS file cache. `experts.bin` → one aligned read per blob (1.38 MB). GGUF‑in‑place → **three reads per expert** (gate/up/down are separate tensor slices), fetched on **8 threads** (`STRATA_FETCH_THREADS`) with one batched page request (Windows `PrefetchVirtualMemory`, elsewhere `madvise(WILLNEED)`). So: medium‑block (1.38 MB) semi‑random for `experts.bin`; smaller 3‑part reads for GGUF. [FROM-CODE]
- **Startup load:** sequential, parallel `fread` on per‑thread handles, 8 MiB chunks, FNV‑1a per layer; **~1.4–1.5 GiB/s** to load 34 GB in ~35 s (`pinned.hpp` `load_experts`; Windows `basic_filebuf` splitting into 4 KB reads was a 0.03 GiB/s bug, fixed by raw `fread`). [FROM-CODE]+[FROM-DOCS]

---

## 5. N‑gram table, speculative/MTP decoding, quantization

### "N‑gram table" = the PLE per‑layer‑token‑embedding table (SSD tier)
This is **not** a classic n‑gram language model; it is a *learned per‑layer input embedding* gathered by an n‑gram **hash** (`ngram.hpp`, `ple.hpp`, `ple_reader.hpp`). [FROM-CODE]
- Tensor `per_layer_token_embd.weight`, **IQ4_NL, [160, 320,001,536] = 51.2e9 elements ≈ 28.8 GB**, read from the model's *second GGUF shard* (not the canonical pack). Each row = 160 values = 90 B.
- Host hash (`ngram_rows`): from the last 3 token ids, 16 row indices per token via 64‑bit multiply/XOR (bigram heads 0–7, trigram heads 8–15), `% vocab_size` (vocab sizes are non‑power‑of‑two primes), EOS cut propagates to older positions. Done on CPU because "ggml has no int64 and no xor." Gathered rows flatten head‑slowest into a 2560‑wide vector consumed by the PLE block. [FROM-CODE]
- Format can also be F8_E4M3 (the shape Qwen ships natively; IQ4_NL is 8% off per row).

### Speculative decoding — three stacked drafters (all verified exactly)
Output is identical regardless of drafts; the verify window decides every emitted token. [FROM-DOCS]+[FROM-CODE]
1. **MTP draft layer** (`mtp.hpp`, `src/core/mtp.cpp`): the model's own vLLM‑0.30 `qwen4_exp` MTP layer, drafts **up to 3 tokens**; one 48‑layer pass checks them → **2.4–3.2 tokens/pass**. Its projections run Q8_0 MMVQ; attention is dense; 512 MTP experts all in VRAM. The draft head is restricted to a **vocab subset** (`data/draft_vocab*.bin`, `--draft-vocab`): CJK/en/cyrillic variants, ~180 MiB VRAM. [FROM-CODE]+[FROM-DOCS]
2. **Prompt‑lookup / suffix drafter** (`spec/suffix_drafter.hpp`): no weights, no GPU. Open‑addressing trigram index → most‑recent end positions (4 ways), extend backward, propose up to 5 tokens. Used only when output quotes input (code edits 6–11% faster). ~20 B/history token, O(1) append. A `draft_policy`/`controller` (`spec/`) gates it by measured acceptance vs cost. [FROM-CODE]
3. **Coupled draft sampling** (`coupled_draft.hpp`, `STRATA_SPEC_COUPLED=1`, off by default): under temperature>0 the MTP samples with the target's own chain and the *same Philox draw* the verify row will use, so draft and target inverse‑CDF picks agree far more often than argmax‑vs‑sample — raising acceptance without changing the output distribution. [FROM-CODE]

### Quantization formats [FROM-CODE]+[FROM-DOCS]
- **Experts (CPU path):** Q2_0 (`cpu/expert.hpp`, 18 B/64 weights, one fp16 scale; activations Q8_0/Q8_1, 32‑elem chunks). Also i‑quant packs **IQ2_XS, IQ3_XXS, IQ3_S** (ggml CPU/GPU kernels in `iq_kernels.cu`), the **Coder IQ1_M** (IQ2_S–IQ4_XS gate/up, IQ4_NL/Q2_0 down; 256 of 512 experts kept), and Unsloth **UD‑Q4_K_XL**. GPU hit kernels use Q8_0 MMVQ (`native_mmvq.cu`, `s2_expert_grouped.cu`).
- **Dense weights:** mixed — BF16 re‑rounded to 16‑bit, plus Q4_0/Q5_0/Q8_0/IQ4_NL tensors with fp16 scales widened to f32 (`weights.hpp`).
- **PLE table:** IQ4_NL or F8_E4M3.
- **KV cache:** fp16 default; **Q8 ≥4K**, optional **Q4_0** (Hadamard‑rotated, −8–12% perplexity), hybrid **K8V4** (keys 8‑bit, values rotated 4‑bit, −23% KV memory) (`kv_q4.hpp`, `kv_q8.hpp`, `kv_stream.hpp`). [FROM-CODE]+[FROM-DOCS]

---

## 6. Memory requirements, context behavior, prefill, bottlenecks

### Memory (reference numbers, `docs/DETAILS.md`) [FROM-DOCS]
| Model | Download | RAM (experts+overhead) | Notes |
|---|---|---|---|
| Q2_0 | 66 GB | ~34 + ~6 GB | fastest |
| IQ2_XS | 68 GB | ~36 + ~6 GB | slightly better quality |
| IQ3_XXS | 76 GB | ~43 + ~6 GB | best, more CPU work |
| Coder IQ1_M | 29.6 GB shard1 | ~23 GB | **fits 32 GB RAM** |
| Unsloth UD‑Q4_K_XL | 111 GB | 72 GiB experts | SSD‑streamed, 7–8.5 tok/s |

- Min **12 GB VRAM** (8 GB "runs slowly"), **64 GB RAM recommended**, ~70–80 GB SSD for the model + 28.8 GB PLE. [FROM-DOCS]
- **Low‑RAM modes** (the directly Apple‑relevant part):
  - `--mmap-experts`: map `experts.bin` (or GGUF shards in place, 0.1.31), OS cache holds what GPU doesn't; committed RAM on Coder drops 36→~13 GB. [FROM-DOCS]
  - `--resident-experts` (0.1.30): copy exactly the experts the GPU *doesn't* hold into RAM at start (page‑locked if possible) → **zero SSD reads in steady state**. Keeps a 4 GB free‑RAM headroom (`STRATA_RESIDENT_HEADROOM_GIB`).
  - `--resident-budget-gib N` (0.1.31): copy the N GiB hottest non‑cached experts to RAM, read the rest from SSD, with router lookahead warming. This is what runs 72 GiB of experts on 64 GB. [FROM-DOCS]
  - `choose_resident_keep_from`/`pin_cache_complement` (`expert_source.hpp`) implement the RAM/SSD partition and the prompt‑path "lend region" (borrow GPU cache slots during prefill, restore after). [FROM-CODE]

### Context / KV behavior [FROM-DOCS]+[FROM-CODE]
- Trained context **262,144** (rope base 1e7); experimental rope scaling (`linear`/`yarn`) past that (`rope_scaling.hpp`).
- **KV streaming ≥64K** (`--kv-resident 32768`): keep only the hot window in VRAM, stream the tail from RAM, freeing VRAM for experts (Q2_0 @262K: 50.9→62.6 tok/s, 1,589→3,872 cached experts). Clock‑sweep page residency on device (`kv_stream.hpp`). ~13.7 KB RAM/token.
- **Conversation/prompt cache** (`conversation_cache.hpp`, `conversation_snapshot.hpp`): up to 6 RAM checkpoints (~118 MB each), reused only on exact token+image prefix; a kept system‑prompt root lets new chats skip the shared prefix. Optional multi‑conversation parking (`--conversation-cache-mib`). One request at a time (v1). [FROM-DOCS]

### Prefill optimizations [FROM-DOCS]
8,192‑token chunks (`--prefill auto`), experts multiplied by ggml quantized **MMQ** kernels (no FP16 expansion), next‑layer experts streamed over PCIe during attention, PLE block run per whole chunk, unpinned experts copied by helper threads. Result ~2× prompt speed (Q2_0 32K: 572→1,290 tok/s). Prefill is largely **GPU/PCIe‑bound and well overlapped**; decode is not.

### Known bottlenecks (authors' own, `expert_cache.hpp`, `pinned.hpp`, docs) [FROM-CODE]+[FROM-DOCS]
1. **The exposed CPU expert miss stream** — 663.6 MB/token, 96% unhidden, serial residual chain. The entire GPU cache + PCIe split + lookahead exist to shrink it. This is *the* bottleneck.
2. **RAM bandwidth** (~40–44 GB/s) and **TLB reach** — 34 GB at 4 KB pages = 8.3 M TLB entries; large pages matter but need `SeLockMemoryPrivilege` on Windows (usually absent), so the common case is the slower normal‑page fallback.
3. **PLE random‑read latency** (2.1–2.6 ms/token via mmap; mitigated by direct I/O + batched prefetch).
4. **Lazy GPU submission** defeating CPU/GPU overlap (measured, `hit_poke` A/B).
5. **mmap eviction** — 34 GB experts + 26.8 GB PLE > RAM means file‑backed pages get dropped and re‑fault from disk; the `PinnedArena` (anonymous, locked) exists specifically to avoid this (engine ran 19 GB/s mapped vs 42.8 GB/s anonymous).
6. **Cold start** — 34–55 GB into RAM; Windows Task Scheduler throttling → 24× slower load.

---

## 7. CUDA/ROCm vs ggml vs portable‑to‑Metal vs unified‑memory

### CUDA/ROCm‑specific (the bulk of the GPU engine) [FROM-CODE]
- All GPU kernels are `.cu` under `src/kernels/cuda/` (≈760 KB): `qsa*`, `gdn.cu`/`fused_gr.cu`, `native_mmvq.cu` (65 KB), `s2_expert_grouped.cu` (64 KB), `iq_kernels.cu` (76 KB), `sampler.cu`, `s_gemv.cu`, etc. They assume **SIMT warps, `__shfl`/dp4a, CUDA streams, CUDA Graphs, cudaHostRegister/pinned+UVA zero‑copy, events**.
- **ROCm/HIP is supported by a thin macro shim** (`include/strata/hip_compat/cuda_runtime.h`): `#define cudaMalloc hipMalloc`, `cudaStream_t→hipStream_t`, `cudaGraph*→hipGraph*`, etc., force‑included into every `.cu`. HIP works *only* because it is literally CUDA with renamed symbols, same SIMT/graph/pinned‑UVA model (`cmake/hip_backend.cmake` targets wave32 RDNA2/3/4 gfx1100/1201). **There is no analogous path to Metal** — Metal has no CUDA‑Graph equivalent, no `__shfl` with the same semantics, no pinned‑host+device‑alias UVA, and MSL ≠ CUDA C++. [FROM-CODE]+[FROM-DOCS]
- Depends on **CUDA‑side host plumbing**: `GpuPlanSink` DMA via copy engine, `cudaHostRegister` of the 34 GB arena for the PCIe miss split, device aliases of mapped host memory. All of this is an artifact of **discrete‑GPU PCIe**.

### Inherited from llama.cpp / ggml (`third_party/ggml`, MIT) [FROM-DOCS]+[FROM-CODE]
- The **i‑quant formats** (IQ2_XS/IQ3_XXS/IQ3_S/IQ4_NL) and their dequant/dot code, transcribed into `iq_kernels.cu`; the **CPU backend** linked for i‑quant experts; the quantized **MMQ** prefill kernels; `ggml-common.h` codebooks (e.g. `kvalues_iq4nl`); the `mtmd` image encoder; `gguf-py` in tools. Rope/yarn flags and semantics follow llama.cpp. [FROM-DOCS]
- **ggml already has a Metal backend** — so the IQ/Q2_0 *formats* and much of the CPU path are portable; what is *not* portable is Strata's bespoke CUDA kernels and the discrete‑GPU streaming machinery.

### Portable to Metal with moderate effort [INFERRED]
- The **CPU expert kernels** (`cpu/expert.cpp`, AVX‑512 VNNI/VBMI + AVX2 fallback) are x86‑only but the *algorithm* (Q2_0 blocked int8 dot, 2‑bit unpack, two‑scale contract) ports to ARM NEON/`i8mm`/SVE or to an MSL compute kernel. The oracle/scalar reference exists for parity.
- The **host architecture** — tiering, profile/adaptive residency, router lookahead prefetch, suffix drafter, conversation cache, direct‑I/O PLE reader (already has a Linux O_DIRECT path; macOS has `F_NOCACHE`) — is plain portable C++.
- The **CUDA Graph‑captured** decode/MTP path and grouped hit/PCIe kernels would need a full Metal rewrite.

### Made unnecessary / advantaged by Apple unified memory [INFERRED — this is the crux]
Strata's **hardest, most fragile machinery exists only to cross PCIe between separate VRAM and RAM**:
- No separate VRAM copy → **no `cudaHostRegister` of a 34 GB arena, no pinned staging, no DMA copy engine, no PCIe miss‑fraction split, no device‑alias of mapped host memory, no "lazy submission" overlap hazard.** On M‑series, GPU and CPU/ANE read the *same* physical pages.
- The **GPU "expert cache" vs RAM distinction largely collapses**: an expert resident "in RAM" is already readable by the Metal GPU at full LPDDR bandwidth. The tiering question becomes **RAM vs SSD only**, not GPU/RAM/SSD.
- KV streaming's "resident window in VRAM, tail in RAM" is unnecessary; all KV is uniformly accessible.
- **But** the M1 Pro's ceiling is **memory bandwidth** (~200 GB/s shared) and **32 GB capacity shared with the OS**, vs the reference box's 64 GB RAM + separate 12 GB VRAM + 40 GB/s CPU DRAM. Unified memory removes the copies but does **not** remove the fundamental "663.6 MB of experts per token" problem — at 200 GB/s that is ~3.3 ms/token *if fully in RAM*, which is excellent, but 34 GB of Q2_0 experts + 4.5 GB dense + 28.8 GB PLE **do not fit in 32 GB**, so SSD streaming of experts is mandatory and that is bandwidth/latency‑bound on the external SSD.

---

## 8. Direct port vs Mac‑specific implementation; minimal viable subset

### Verdict: **A direct port is not sensible; a Mac‑specific implementation is the right call.** [INFERRED]

**Why not a direct port.** The 760 KB of CUDA kernels and the entire host‑side streaming apparatus are built around the discrete‑GPU PCIe boundary that Apple Silicon does not have. HIP works only as a symbol rename; Metal is a different language and execution model with no CUDA‑Graph/pinned‑UVA analogues. You would be rewriting every `.cu` kernel *and* discarding the half of the engine (pinned arena, PCIe split, cache fills, KV VRAM window) that only exists to fight PCIe. Porting it faithfully would reproduce complexity that unified memory makes pointless.

**What is genuinely worth stealing (the portable, architecture‑level ideas):**
1. The **tiering philosophy** — but re‑cast as **RAM (hot) ↔ SSD (cold)**, dropping the GPU/RAM split entirely. On 32 GB unified, the real decision is which experts and how much PLE live in RAM vs stream from the 2 TB SSD.
2. The **offline frequency profile + decayed online adaptation** (`make_profile.py` + `ExpertDispatch::usage`) — directly reusable; this is the single highest‑leverage idea and it is pure data/C++.
3. **Router‑lookahead prefetch** (`RouterLookahead`) — apply next layer's router to this layer's input to warm SSD pages ahead of need. This is *more* important on Mac, where experts stream from SSD, and it is GPU‑agnostic.
4. **Direct, unbuffered, many‑in‑flight SSD reads** with the PLE kept off‑RAM (`direct_file.hpp`; macOS `fcntl(F_NOCACHE)` / `preadv`), plus batched prefetch and a small row cache.
5. The **three‑drafter speculative stack** (MTP + suffix + coupled) — all verified‑exact, GPU‑model‑agnostic in concept; MLX has the matmuls to implement MTP.
6. The **correctness discipline**: per‑tensor shape checks at load, FNV‑1a per‑layer checksums, activation‑contract parity, "never resume into a plausible wrong token."

**Why MLX/Metal natively is better than porting:** unified memory means an "expert in RAM" is already on the GPU. The engineering collapses from "cache hot experts in VRAM, DMA misses, split the rest CPU/PCIe, keep KV window in VRAM" to "keep hot experts + dense + as much PLE as fits in the 32 GB working set, stream the cold tail from SSD with lookahead prefetch, compute everything on the Metal GPU (or ANE where it fits)." The CPU AVX‑512 expert path becomes unnecessary — the GPU computes all experts; only the *source* (RAM vs SSD) differs.

### Minimal viable subset (recommended build order) [INFERRED]
1. **Metal/MLX dense + MoE forward** for Qwen3.8‑Flash‑Next at Q2_0/IQ‑quant (12 QSA + 36 GDN layers, gated residual, shared expert, top‑10 router). Everything RAM‑resident first, correctness‑gated against ggml/llama.cpp token‑for‑token (reuse Strata's parity mindset). This proves the model runs on Metal at all.
2. **Two‑tier expert residency: RAM ∪ SSD**, driven by the shipped frequency profile; mmap or direct‑read experts not in the RAM budget, through the OS unified buffer cache. Add the decayed‑count adaptive swap between RAM and SSD.
3. **Router‑lookahead SSD prefetch** + direct‑I/O PLE reader (28.8 GB, never RAM‑cached). These two make the SSD tier tolerable; without them SSD streaming dominates (cf. 7–8.5 tok/s).
4. **MTP speculative decode** (biggest single decode speedup, 2.4–3.2 tok/pass), then the suffix drafter for code.
5. Defer: KV VRAM‑window streaming (unneeded on unified memory — all KV is accessible), multi‑GPU, the PCIe miss split, `cudaHostRegister` arena — all discrete‑GPU‑only.

**Feasibility sanity check for the Phase‑A question (M1 Pro 32 GB).** The Coder (IQ1_M, ~23 GB experts) or Q2_0 with a RAM budget is the realistic target: dense (~4.5 GB) + a hot‑expert RAM budget + PLE streamed from SSD. Full Q2_0 (34 GB experts) + PLE (28.8 GB) cannot be RAM‑resident in 32 GB, so expert *and* PLE SSD streaming is mandatory and the external SSD's random‑read latency/bandwidth is the governing limit — exactly the regime where Strata itself falls to single‑digit tok/s. **Unified memory removes the copy tax but not the capacity wall; the external SSD and its 4 KB random‑read latency will set the ceiling.** Expect "works, usable for the Coder; slow for full Q2_0 unless a large fraction of experts fit the RAM budget." (This is an engineering estimate, not measured.)

---

## Key takeaways for Apple Silicon

1. **Strata's design is 70% portable idea, 30% non‑portable plumbing.** The portable 70% (tiering, frequency profile + adaptive residency, router‑lookahead prefetch, direct‑I/O PLE, 3‑stage exact speculative decode, parity discipline) is exactly what an M‑series MoE‑streaming engine needs. The non‑portable 30% (CUDA/HIP kernels, pinned 34 GB arena, PCIe miss split, KV VRAM window) exists only to cross the discrete‑GPU PCIe gap. [INFERRED]
2. **Unified memory deletes the engine's hardest problem.** No VRAM/RAM copy, no `cudaHostRegister`, no DMA staging, no CPU/PCIe miss split, no "did the GPU actually start overlapping" hazard. The tiering reduces to **RAM ↔ SSD**. [INFERRED]
3. **But capacity is the wall, not copies.** 34 GB Q2_0 experts + 28.8 GB PLE ≫ 32 GB. SSD streaming of experts is mandatory; this is the regime where Strata itself drops to ~7–8.5 tok/s (Unsloth 72 GiB on 64 GB). The external ~2 TB SSD's random‑read latency governs. [FROM-DOCS]+[INFERRED]
4. **The PLE table (28.8 GB, 16 random 90 B rows/token) is a latency problem, not bandwidth** — direct unbuffered I/O + batched prefetch is the right pattern on macOS (`F_NOCACHE`). Keep it off the unified RAM. [FROM-CODE]
5. **Router‑lookahead prefetch is the highest‑leverage portable trick** for SSD‑backed experts — apply layer l+1's router to layer l's input to warm pages ahead. More important on Mac than on the reference box. [FROM-CODE]
6. **Drop the CPU expert kernel entirely on Mac.** On unified memory the Metal GPU computes all experts regardless of RAM/SSD source; the elaborate AVX‑512 VNNI path and the hot/cold CPU‑GPU split are discrete‑GPU artifacts. [INFERRED]
7. **Reuse the profile format and the correctness gates verbatim** (`make_profile.py` STRP file, per‑layer FNV‑1a, shape checks, activation‑contract parity). These are data/C++ and encode hard‑won lessons. [FROM-CODE]
8. **Recommendation: build Mac‑native (MLX/Metal), not a port.** Minimal viable path = Metal MoE forward (RAM‑resident, parity‑gated) → RAM∪SSD expert residency via profile → router‑lookahead + direct PLE I/O → MTP speculative decode. Target the Coder/IQ1_M first (fits a 32 GB RAM budget best). [INFERRED]

## Things I could not verify / caveats
- All performance numbers are the **authors' own**, mostly on one RTX 5070/Ryzen 7600/64 GB box; many are explicitly in‑sample, extrapolated, or "not measured again." Treat ±20–30%. [FROM-DOCS]
- I did **not** read the full `src/program/generate.cpp` (424 KB), `src/core/layer.cpp` (104 KB), or `expert_source.cpp` (110 KB); the decode‑loop ordering and exact overlap are taken from headers + docs. [limitation]
- `include/strata/kernels/ngram.hpp` contains a stale "THERE IS NO LINUX" comment (Windows‑era module note); `direct_file.hpp` and the docs confirm Linux is fully supported (O_DIRECT, Ubuntu auto‑install). Don't read that comment as the engine's OS support. [FROM-CODE]
- "24,576 experts / 10 per token" and model size numbers are consistent across docs and code (`48×512`, top‑10). The marketing "125B" figure (GitHub blurb via search) wasn't found in‑repo; the repo describes it only as Qwen3.8‑Flash‑Next. [FROM-CODE]
- No Metal/MLX code exists in the repo; the Apple‑portability conclusions are my analysis, not the authors'. [INFERRED]

## Sources
- Repo root: https://github.com/mach10x/strata — README.md, AGENTS.md
- https://github.com/mach10x/strata/blob/main/docs/HOW_IT_WORKS.md
- https://github.com/mach10x/strata/blob/main/docs/DETAILS.md  (richest: speed tables, low‑RAM modes, KV streaming, prefill, "How it works")
- https://github.com/mach10x/strata/blob/main/docs/MODELS.md , docs/MULTI_GPU.md, docs/AMD_HIP.md, docs/UNSLOTH_Q4.md
- https://github.com/mach10x/strata/blob/main/docs/paper/Strata-Paper.pdf  (referenced; not parsed here)
- Code — tiering/experts: include/strata/core/expert_source.hpp, expert_cache.hpp, remote_experts.hpp, pinned.hpp, weights.hpp, layout.hpp; src/core/expert_source.cpp, expert_cache.cpp (not fully read)
- Code — CPU kernel: include/strata/kernels/cpu/expert.hpp; src/kernels/cpu/expert.cpp, q2_avx2.cpp
- Code — router: include/strata/kernels/router_top10.hpp; src/kernels/cuda/router_top10.cu
- Code — PLE/n‑gram + SSD: include/strata/kernels/ngram.hpp, include/strata/ngram/ple_reader.hpp, include/strata/platform/direct_file.hpp
- Code — speculative: include/strata/core/mtp.hpp, coupled_draft.hpp; include/strata/spec/suffix_drafter.hpp, draft_policy.hpp, controller.hpp
- Code — KV: include/strata/kernels/kv_stream.hpp, kv_q4.hpp, kv_q8.hpp
- Code — backends: cmake/hip_backend.cmake, include/strata/hip_compat/cuda_runtime.h, src/kernels/cuda/*.cu, third_party/ggml/
- Tools: tools/make_profile.py, tools/iq_pack.py, tools/mtp_rt.py
- Benchmarks: bench/results/2026-09-2x-* (speed, prefill, layer-split, rtx3090-epyc-milan, community-rtx-5090)
- Not the same project: arXiv 2510.05245 "Stratum" (3D‑stackable DRAM MoE) — unrelated despite name collision.
