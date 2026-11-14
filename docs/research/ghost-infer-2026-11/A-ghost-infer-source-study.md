# ghost-infer: source-code study

- Repo: https://github.com/affifuddin-hazam/ghost-infer
- **Pinned revision: `2f2a985bf74c8e0e4b288cadb68e77bfc9a554de`** (HEAD, committed 2026-11-14 10:02 +0800, "README, benchmarks and social preview: 2026-11-14 numbers…"). Version string in `Cargo.toml` is 0.4.0.
- Method: cloned with `--depth 50 --filter=blob:limit=1m`, then unshallowed with the same blob filter for history only. **Nothing was built or executed**; only `cat/grep/sed/wc/git log` were used. Every `file:line` below refers to the pinned SHA.
- Labels used: **[IMPL]** means the code is there and wired in; **[DOC]** means it is a claim from the docs or a commit message that I could not verify by running anything; **[EXP]** means it is behind an opt-in environment variable, experimental or a test path; **[TODO]** means roadmap only.

---

## 1. Overview

| Item | Finding |
|---|---|
| Languages | Rust for the engine and server (`src/*.rs`, `src/server/*.rs`, 31,525 lines, about 4,725 of which are CUDA C++ inside a Rust raw string, `src/cuda.rs:143–4868`), plus `src/iq_tables.cu` (322 lines, `include_str!`'d). Desktop app in Rust/iced (`app/src`, 9,481 lines). Python helper and conversion scripts (about 3.8k lines), PowerShell bench and installer scripts (about 1.4k), and a large single-file chat UI `src/chat.html` (1,663 lines, about 105 KB). 83 `#[test]`s in the engine. |
| Build | Cargo workspace (`Cargo.toml`: members `"."` and `"app"`). Engine dependencies are only `memmap2 = "0.9"` and `rayon = "1.10"`. There is **no `build.rs`**. `.cargo/config.toml` sets `-C target-cpu=native`. Release profile: thin LTO, `panic = "abort"`. |
| License | **Dual `MIT OR Apache-2.0`** (`Cargo.toml` `license =`; `LICENSE-MIT`, `LICENSE-APACHE`). MIT: "Copyright (c) 2026 affifuddin-hazam". Apache-2.0 is the stock text (patent grant §3, NOTICE handling §4); there are no extra clauses or NOTICE file. The installer bundles third-party notices (`installer/THIRD-PARTY.txt`, which covers the NVRTC redistributable). The vendored `three.module.min.js` and Instrument Sans fonts have their own LICENSE files. |
| History | 139 commits from **2026-10-24** (`577b265`, "betterllama: GGUF inference engine for CPU and NVIDIA GPU") to 2026-11-14: **3 weeks old**, very high velocity (85 commits in Oct, 54 in Nov). |
| Contributors | Effectively **one**: `affifuddin-hazam` (137 commits, plus 1 as "Apiz Pudin", the same noreply address) and `huai_xin` (1 commit, Chinese i18n of the app, PR #1). |
| Platforms | **Windows only.** CUDA is reached by `LoadLibraryExW("nvcuda.dll")` plus a discovered `nvrtc64_*.dll` (`src/cuda.rs:4875–4952, 5071–5127`). On non-Windows the `os` module is a stub whose `open()` returns `None` (`src/cuda.rs:4954–4970`), so there is **no GPU on Linux or macOS**. There is no Vulkan, Metal, ROCm or OpenCL, and nothing like `target_os = "macos"` or `aarch64`/NEON anywhere. The CPU kernels are AVX2/FMA on `x86_64` with a scalar fallback (`src/quant.rs:777–786`, `has_avx2()` returns false off x86). The docs say "Windows only for now (Linux is on the roadmap)" (`docs/building.md`). |
| CUDA | No CUDA SDK at build time. The kernels are compiled at first start by **NVRTC** to a cubin for the detected `sm_XY` and cached under `%LOCALAPPDATA%\ghost-infer\kernels\<hash>.cubin` (`Kernels::binary`, `src/cuda.rs:5462–5541`). NVRTC must be 11.1 or newer, and the GPU must be compute capability 6.1 or newer (needs `dp4a`); sm_75+ adds int8/f16 tensor-core paths (`mma.sync`, `ldmatrix`) (`docs/building.md`). **No cuBLAS, cuDNN or CUTLASS**: every kernel is hand-written. Only the driver API is used (`api!` table, `src/cuda.rs:4972–5035`), including virtual-memory APIs (`cuMemCreate/Map/AddressReserve`) for a weight arena (`Arena`, `src/cuda.rs:5287–5350`), streams, events, graphs and host-mapped memory. |
| Architectures | `SUPPORTED_ARCHS = ["llama", "qwen3", "qwen3moe", "deepseek2", "qwen3next", "qwen35", "qwen35moe"]` (`src/model.rs:135`). `deepseek2` is used for GLM-4.7-Flash's MLA plus sigmoid-routed MoE. `qwen3next`, `qwen35` and `qwen35moe` are the Gated DeltaNet hybrids. GPU limits: MLA only with a 512-wide latent and at most 32 heads, DeltaNet heads exactly 128, gated attention heads 128 or 256 (`GpuModel::load_with`, `src/cuda.rs:7786–7801`). Also present: Whisper STT, CSM and maya1 TTS (with SNAC/Mimi codecs), and YuE2 (music LM) as side models. **Not supported:** Gemma, vision, and any SentencePiece tokenizer (`src/tokenizer.rs:199–201` requires `tokenizer.ggml.model == "gpt2"`). |
| GGUF quant types read | `GgmlType` (`src/gguf.rs:96–157`): F32, F16, BF16, Q8_0, Q4_0, Q4_1, Q5_0, Q5_1, Q3_K, Q4_K, Q5_K, Q6_K, IQ4_NL, IQ2_XXS, IQ2_XS, IQ2_S, IQ3_S, plus two non-upstream ids: `42 = Q2_0` and `143 = PTQ1_0` (PrismML's ternary fork). **Q2_K, IQ1_*, IQ3_XXS, IQ4_XS and MXFP4 are missing** (`docs/building.md`: "Not yet: other IQ formats (IQ1, IQ3_XXS, IQ4_XS)"). The legacy formats and BF16 are dequant-only. GGUF v2 and v3 are accepted (`src/gguf.rs:303–358`). |

---

## 2. Inference engine

**GGUF parsing and mmap [IMPL].** `Gguf::open` memory-maps the whole file with `memmap2::Mmap` (`src/gguf.rs:303–306`), parses the KV metadata and tensor table, aligns to `general.alignment`, and bounds-checks every tensor's extent (`:340–356`). Tensor lookup is a linear scan (`tensor()`, `:364`). The CPU backend uses weights in place from the map, with no copies (`crate::quant::Matrix { data: &mmap[..] }`).

**Weight placement [IMPL].** `GpuModel::load_with` (`src/cuda.rs:7786–8018`) uploads every **non-expert** tensor to VRAM through a 32 MB pinned staging `Uploader` (`:5747–5940`, `STAGE_BYTES` at `:5760`), reading the file with positioned reads (`read_exact_at`, `:5763`).
- Dense models must fit entirely in VRAM. There is no partial layer offload for dense models (`docs/building.md`: "Dense models must fit in VRAM").
- MoE experts stay in the file mapping (`CpuMoe::load`, `:6617–6660`).
- The token-embedding table stays on the host (`Embd::Host`, `:7925–7940`) for MoE models, for tables of 256 MB or more, and for Hadamard-rotated models. The VRAM it would have used goes to the expert cache.
- After upload the whole mapping is dropped from the working set (`os::release` → `VirtualUnlock`, `:7997–8002`), so the uploaded trunk isn't held twice.

**On-GPU formats** (`enum Fmt`, `:5959–5973`; `upload_parts_as`, `:6117–6206`):
- Q4_K stays in raw GGUF blocks.
- Q6_K is repacked to 208-byte blocks plus a separate `d`.
- Q3_K is repacked to 112-byte aligned blocks, which keeps it 3-bit for decode.
- IQ2 and Q2_0/PTQ1_0 stay as they are in the file.
- **Q5_K, Q8_0 and the rare formats are requantized to int8 plus an f32 scale per 32** (comment at `:6150`: "no 5-bit GPU kernels yet… about 1.5x the memory").

**Quantized matmuls [IMPL].**
- **Decode (one token):** `dp4a` matrix-vector kernels that read packed K-quant blocks directly, with activations pre-quantized to int8 by fused `rmsnorm_q8` / `silu_q8` (comment block `src/cuda.rs:747–770`; instantiations `:1425–1441`). This is dequant-on-the-fly into integer dot products, not to floats. Rows per warp are tunable (`GHOST_INFER_RPW`, `:42–45`).
- **Verify batches (2–64 tokens):** separate `q4k_vfy`/`q6k_vfy` int8 tensor-core kernels (`mma.sync m8n8k16`, `:1117–1400`). They are written to give **bit-identical results to the 1-token dp4a path**: integer sub-block sums, then an explicitly ordered sequence of `__fmaf_rn`/`__fadd_rn` (`:754–770`).
- **Prefill:** an int8 tensor-core GEMM `matmul_mma` (`:2986`, `ldmatrix` + `mma.sync`, sm_75+). Older GPUs fall back to `matmul_tiled` (dp4a, `:2865`). K-quant prompt activations get one int8 scale per 128 values (`QCH`, `:53–57`). Q3_K and IQ2 weights are converted to Q8 a slice at a time for big batches (`q3k_to_q8`, `iq2_to_q8`).

**Attention [IMPL].**
- **Decode** uses split-context "flash-decoding": `attention_partial_gqa` (`:1684`) reads each KV row once for all G query heads, writing partial results that `attention_combine` (`:2806`) merges. The split count targets about 96 blocks (`ATT_TARGET_BLOCKS`, `:106`), with chunk cap 128 (`att_chunk_cap`, `:100–103`, tuned numbers in the comment). There are also tensor-core decode kernels for 256-wide heads (`attention_decode_tc256`).
- **Prefill** uses "FlashAttention-2 style" f16 `mma.sync m16n8k8` with f32 accumulators and online base-2 softmax, staging the int8 KV as exact f16 integers (`attn_prefill_tc`, comment `:2397–2410`). There is an f32 fallback.
- **MLA** has its own kernels (`mla_attention`, `mla_kv`, `mla_q_rope`) attending over the compressed latent as stored.
- **Gated DeltaNet** uses `delta_conv`, `delta_prep`, `delta_scan` (`:4086–4185`), with one thread per state column and 128 floats in registers (`docs/how-it-works.md`).
- **There is no paged attention.**

**Fusion [IMPL].** `rmsnorm_both` writes the f32 and int8 normalized rows in one launch. Also fused: `silu_q8`, `qk_norm_rope`, `moe_combine_gated_n` (expert sum plus the gated shared expert in one launch), and rmsnorm+matmul (`norm_matmul`, `:8265`).

**CUDA graphs [IMPL].**
- Dense one-token steps are captured once per output kind (Last/Argmax/Hidden) and replayed, with the position read from `pos_dev` (`GpuModel::forward`, `:8662–8685`).
- MoE uses **one graph per layer** between expert hand-offs (`moe_step_graphed`, `:9342–9419`) or the GPU-routed variant (`moe_step_routed`, `:9444–9564`).
- `GHOST_INFER_NO_GRAPH=1` and `GHOST_INFER_NO_MOE_GRAPH=1` turn them off.

**Sampling [IMPL]** runs on the CPU (`src/sampler.rs`): temperature, top-k, top-p, repetition and presence penalties, DRY. A "short-list" top-k avoids scoring the whole vocabulary (`:155–158`; the commit message says greedy went from 607 to 130 µs). `accept()` (`:220–255`) implements exact speculative-sampling acceptance for a draft that is sure of its one token. Greedy argmax can be computed on the GPU (`argmax_rows`).

**Where the speed comes from (dense):** bandwidth-efficient dp4a decode (the doc claims 84–97% of DRAM bandwidth on an 8B) [DOC], a whole-step CUDA graph, an int8 KV cache by default (half the attention bytes of f16), flash-decoding with tuned split sizes, and prompt-lookup speculation on by default for dense GPU models. For MoE models bigger than VRAM, the gain comes from section 3.

---

## 3. MoE (the core differentiator)

**Routing [IMPL].**
- Qwen-style `route` is top-k by logit, then softmax over just those k (`src/model.rs:524–536`).
- DeepSeek/GLM `route_deepseek` is sigmoid or softmax plus a per-expert bias for selection, with optional renormalization and scaling (`:541–562`).
- One-token steps compute router logits on the GPU (`router_logits1`).
- With `routed_ok()` (`src/cuda.rs:9421–9442`: softmax routing, at most 256 experts, k ≤ 8, Q3_K gate/up with a Q4_K or Q5_K down, no IQ2, not GPU-only mode), **top-k itself runs on the GPU**: `moe_topk` (`:1465–1530`) uses a 256-thread rank sort on order-preserving int keys, with ties broken to the lower index to match the host's `total_cmp`.

**Expert cache [IMPL]: `struct ExpertCache`** (`src/cuda.rs:6892–6932`).
- **Data structure:** a pool of fixed-size VRAM *slots*, allocated in blocks of 16 (`SLOT_BLOCK`, `:10314`). It keeps `slot_of[layer][expert] → slot | -1`, an `owner[slot]`, a free list, `used[slot]` (the last layer-step that picked it), `freq[layer][expert]` (u16 pick counts), and `queued` flags. Each slot holds an expert's gate, up and down packed contiguously (`pack_parts`, `:7084–7100`; Q3_K repacked to 112-byte blocks).
- **Capacity:** whatever VRAM is free after weights, session and a 384 MB reserve (`expert_cache_budget`, `:10280–10285`; `FIT_RESERVE`, `:10262`), or `GHOST_INFER_EXPERT_CACHE_MB`. It is created lazily on the first forward pass (`expert_cache_ready`, `:8752`). The benchmarks doc says "about a third" of Qwen3.6-35B-A3B's experts fit on 8 GB [DOC].
- **Cacheability:** only layers whose experts are Q3_K gate/up with a Q4_K or Q5_K down, or uniform IQ2_XXS/IQ2_S (`:6955–6961`). Other quantizations (for example Q4_K_M experts) **are not cached at all**: those layers' experts always run on the CPU for decode. Q4_K_M MoE files therefore do not get the headline speedup; the benchmarks only use i1-Q3_K_M or Q3_K_M files.
- **Replacement policy:** recency eviction gated by frequency (`note()`, `:7193–7261`).
  - A miss takes a free slot if there is one. Otherwise the victim is the slot with the smallest `used` (LRU), excluding experts picked in this step.
  - The swap happens only if `freq[new] > freq[victim]` (frequency-gated admission, added in commit `741202e`). `GHOST_INFER_CACHE_LRU=1` restores plain LRU.
  - Frequencies halve every `FREQ_HALF = 5120` layer-steps, about 128 tokens on a 40-layer model (`:6749`).
  - **Prompt-batch picks are not counted** in `freq` and cannot evict (`prompt` flag; the comment cites 62% vs 77% hit rate on a replayed chat).
  - At most `uploads_per_token() = 12` uploads per token (`:6758–6761`). The comment `:6740–6748` gives trace-replay hit rates (Qwen3-30B-A3B, a third cached): 8/token 72%, 16 80%, 24 84%, unlimited 88%; the older "keep most-picked" cache got 64%.
  - `GHOST_INFER_MOE_TRACE=file` dumps every layer's picks for offline policy replay (`moe_trace`, `:7277–7292`).
- **Hot vs cold:** hot means resident in a VRAM slot and runs on the GPU. Cold runs on the CPU from the mmap.
- **Prefetching:** there is no learned or predictive expert prediction for decode. Admission is reactive: an expert that missed is uploaded for future tokens. For prompts and out-of-core cases, a **layer-ahead disk prefetch** thread (`Prefetcher`, `:6396–6476`) issues `PrefetchVirtualMemory` over each layer's uncached experts as coalesced runs in file order, then touches every page, while the current layer computes (`prefetch_layer`, `:6670–6691`; used in `moe_ffn_batch`, `:9020–9030`). The doc claims a cold 1,000-token prompt from a USB HDD took 151 s instead of 215 s [DOC].
- **Uploads:** `ExpertUploader` (`:6779–6870`) is a background thread with its own **non-blocking CUDA stream**, two pinned host buffers and two events (double-buffered `cuMemcpyHtoDAsync`). When a copy lands it reports the slot and `os::release`s the expert's RAM pages (VRAM-resident experts give their RAM back). It also pre-faults the *evicted* expert's pages back into RAM so the CPU won't page-fault mid-token.

**CPU execution of cold experts [IMPL].**
- `model::moe_experts` (`src/model.rs:879–917`) handles single tokens with `quant::experts_one` (`src/quant.rs:1077+`): AVX2 int8 dot products on a custom **spinning thread pool** (`src/pool.rs`).
- The pool's workers spin for 2 ms between jobs, then park. Each worker is pinned to its own physical core (`SetThreadAffinityMask` with mask `1 << 2i`), and the caller is pinned to core 0 (`pool.rs:61–127`). Workers run below normal priority. Rows are handed out in chunks through an atomic counter (`quant.rs:1084–1106`).
- Commit `9d3d385` claims a CPU expert call went from about 165 to about 142 µs.

**Overlap and synchronization [IMPL].**
- **Host-routed path** (`moe_ffn_rows`, `:8778–9011`): the normalized row and router logits come back with a synchronous D2H copy. The host routes, writes a table of cached-expert pointers to a pinned buffer, and queues `moe_gate_up_q3k` → `silu_q8` → `moe_down_q4k/q5k` on the stream. The CPU computes the misses *while the GPU runs*, then sends its sum asynchronously, and `moe_combine` adds everything.
- **GPU-routed path** (`moe_step_routed` + `moe_routed_host`, `:9444–9637`): each layer is a single graph containing the previous layer's combine plus shared expert, attention, norm, router, `moe_topk`, and the `_n` expert kernels, which read the cached count from device memory and early-exit unused blocks.
  - `moe_topk` writes the picks and the normalized row into **host-mapped memory** and sets a ready word after `__threadfence_system()`.
  - The host **spin-waits on that mapped word** (`:9580–9588`, 20 s timeout), computes the uncached experts on the CPU, and writes the weights and CPU sum into another mapped buffer that the *next* layer's graph head consumes (`moe_combine_n` / `moe_combine_gated_n`).
  - The shared expert's matmuls are put in the graph *before* the hand-off so they overlap the CPU (`moe_shared_part(..., true)`).
  - Commit `866664f` claims 66 → 79 tok/s from GPU routing on 35B-A3B; `5ca0b23` claims 54.8 → 61.6 from per-layer graphs [DOC].
- **Cache bookkeeping** (`note`) is deferred until after the next graph launch, so it overlaps GPU work (`moe_step_graphed`, `:9366–9400`).
- **Prompt batches of 32 or more tokens** (`MOE_GPU_MIN_BATCH`, `:10372`; `moe_ffn_batch`, `:9013–9115`): all experts run on the GPU. Tokens are grouped per expert (gather, then Q8 GEMM, then scatter). Uncached experts are staged through two pinned buffers and two scratch slots so the next expert's H2D copy overlaps the current one's math (`stage`, `:7102–7136`).
- **Batches of 2–31 tokens** run token by token as one-token steps so their arithmetic matches decode (`moe_ffn`, `:8733–8749`).
- **Optional "GPU-only experts"** (`moe_gpu_only`, `:10399–10408`): misses are packed in parallel with rayon and copied to per-pick device slots instead of running on the CPU [EXP/opt-in setting].

**PCIe and memory-bandwidth reasoning** (from comments): each upload "moves ~2 MB through RAM and PCIe… bandwidth the CPU's experts share" (`:6740`). Throughput measured against uploads-per-token peaks at 12 (8 → 30.5, 12 → 33.0, 16 → 32.8, 24 → 28.8 tok/s through the server). The design trades PCIe uploads against DDR bandwidth spent on CPU experts.

**Weights bigger than VRAM, or bigger than RAM [IMPL].**
- KV grows in 4,096-token steps for MoE (`CTX_STEP`, `session_grows`, `:10362–10370`). Growth frees expert-cache blocks to make room (`fit_session`, `:9877–9906`; `free_blocks`, `:7049–7071`). The default MoE context is 8,192 (`MOE_DEFAULT_CTX`).
- A **RAM floor** (Windows only) is enforced by a `Trimmer` thread (`:6533–6592`). Four times a second it `VirtualUnlock`s the least-recently-used expert pages that haven't been used for 2 s until available RAM is back above the floor. When RAM is short, prompt staging uses `pread` instead of the mapping (`ram_short`, `:6504–6508`; `stage`, `:7112–7126`).
- Qwen3-Next (80B, IQ2) runs prompts in 4,096-token passes so experts are streamed once per pass (`max_batch`, `:19–25`).

---

## 4. Speculative decoding

**Prompt-lookup / n-gram drafting [IMPL]** (`src/lookup.rs`, wired in `main.rs:702–726` and `lookup_decode`, `main.rs:941–1036`).
- **Index:** a HashMap from each adjacent token pair to its positions (`Lookup`, `lookup.rs:33–76`).
- **Draft:** take the occurrences of the last two tokens, look at the 48 most recent (`MAX_CANDIDATES`), extend each match backwards up to 24 tokens (`MAX_MATCH`), pick the longest (ties go to the most recent), and propose the tokens that followed (`draft`, `:80–100`).
- **Adaptive draft length (`Pace`, `:103–276`):**
  - It keeps a moving-average time for a plain step and per-batch-size verify costs (with a prior cost curve `usual_cost`, `:151–154`, measured on an RTX 2060S).
  - It keeps fading acceptance stats per match-length bucket (2, 3, 4–5, 6–9, 10–15, 16+) with optimistic priors.
  - It chooses k to maximize the expected tokens/s, `(1+q+…+q^k)·step/cost(k+1)`, requiring a gain above 1.05.
  - A safety net stops drafting with doubling back-off (16 to 512 plain steps) when recent rounds lose.
- **Verification:** greedy keeps guesses while argmax matches. Sampled decoding uses `Sampler::accept` for exact distribution-preserving acceptance (`main.rs:977–993`).
- **Batch limit:** `VERIFY_MAX_BATCH = 64` (`cuda.rs:129`).
- **Scope:** on by default for dense GPU models; `--no-lookup` or `GHOST_INFER_NO_LOOKUP` turn it off. It is **off for MoE** unless `GHOST_INFER_MOE_LOOKUP=1`, because each checked token's experts run as a one-token step, so k guesses cost about k steps (the comment at `main.rs:702–705` measured 31.1 vs 32.4 tok/s, i.e. a loss). It is also off for MLA.
- **Recurrent models:** DeltaNet state is saved and restored around verify, then the accepted prefix is replayed (`main.rs:996–1000`).
- **Target workload:** agents and coding, where the reply copies earlier text. The README claims 3.2× "on agent work that copies text" [DOC].

**Draft-model speculation [IMPL]** (`speculate`, `main.rs:835–930`).
- GPU only and **greedy only** (`generate_with`, `:679–700`). The draft must have an identical tokenizer, checked by vocab size and a probe string (`load_with_draft`, `:585–590`).
- The draft runs with int8 activations even on Q8_0 (`int8_q8 = true`).
- The draft length is **fixed** (`--draft-k`, default 3, maximum 7 since `DECODE_MAX_BATCH = 8`). There is no adaptation.
- The draft proposes k tokens autoregressively. The main model verifies `[last, guesses…]` in one batch (`forward_argmax`), accepts the longest matching prefix, rolls back by resetting `pos` (or restores state for recurrent models), and keeps the draft's cache in sync.
- Acceptance stats are printed (`print_draft_stats`).
- **Exactness:** because the verify kernels are batch-invariant (`cuda.rs:754–770`, `:1117–1125`, and attention via `attention_vfy_*`, `:2046+`), the output equals plain greedy bit for bit.
- **Interaction with prefill:** the draft prefills whatever it missed plus the prompt before decoding (`main.rs:679–685`). Sampled requests skip the draft.

---

## 5. KV cache

- **Allocation:**
  - Dense models get a **static** per-layer contiguous buffer sized to `ctx` (`LayerCache`, `cuda.rs:9916–9949`). The default `ctx` is the largest multiple of 1,024 that fits free VRAM (`fit_ctx`, `:10463–10493`). Prompt batch size can be lowered to 256 to buy context (`BATCH_CAP`).
  - MoE models get a **growing** cache in 4,096-token steps, with copy-on-resize (`LayerCache::resize`) and expert-cache rebalancing.
  - **Not paged.** No block tables. Fragmentation is handled by whole-buffer reallocation per layer.
- **Quantized KV:**
  - Default **int8 with an f32 scale per (position, kv-head)** (`kv_mode`, `:59–72`; `cache_rows`, `:10181–10195`).
  - `--kv f16` is available.
  - `--kv q4` gives 4-bit values with an f16 scale per 32 after a **normalized 256-point Walsh–Hadamard rotation** of K/V rows, with queries rotated to match and the output rotated back. It applies only to 256-wide GQA heads (Qwen3.5/3.6/3.8 attention layers) on sm_75+ (`kv4`, `:73–89`); 144 bytes per row vs 260 for int8. The comment reports +0.1–0.3% perplexity over int8 and 97.7–98.6% top-1 agreement on Bonsai 27B. The app's server uses it by default (commit `669b975`).
  - MLA caches one f16 latent row per token.
- **Prefix reuse:**
  - Within a session, the server keeps the last conversation and computes the common prefix with the new request (`server.rs:629, 680`). Only the suffix is prefilled; a non-recurrent truncate just moves `pos` (`GpuSession::truncate`, `cuda.rs:10154–10173`).
  - Across requests, **"openings" are kept in host RAM**: the prompt up to the first end-of-turn token, if it is at least 512 tokens. `SavedState` copies every layer's K/V and scales (and DeltaNet state) to pinned host memory and restores it on a later match, up to 2 openings in LRU order (`Engine::opening`, `main.rs:773–813`; `keep`/`load`, `cuda.rs:10115–10152`; `OPENING_MIN`/`MAX_OPENINGS`, `main.rs:543–545`). The purpose is to switch between an agent's and a subagent's system prompts cheaply.
  - **DeltaNet snapshots:** up to 5 copies of the recurrent state in pinned host memory (`MAX_SNAPS`, `:10320`; `snapshot`, `:10101–10112`). Recurrent state cannot be truncated, so the engine rolls back to the nearest snapshot.
- **Context scaling:** int8 KV roughly doubles context (the doc gives 19,456 vs 10,240 tokens for an 8B on 8 GB). Long-context decode stays fast through tensor-core decode attention for 256-wide heads (README claims 12.3 → 49.1 tok/s after 64K on 35B-A3B) [DOC].

---

## 6. Runtime

- **Startup:**
  - Loading the driver and NVRTC, compiling or loading the cached cubin, then streaming weights from file to the arena (`GHOST_INFER_LOAD_TIMES` prints the phases, `cuda.rs:8005–8016`).
  - The doc claims 1.9 s to ready for an 8B with the file in the OS cache [DOC].
  - Weights are loaded with positioned file reads through pinned staging, not through page faults. After upload, mapping pages are released from the working set.
- **mmap and prefetch:** the CPU and expert paths read from `memmap2` mappings. Explicit `PrefetchVirtualMemory` plus page touching runs one layer ahead for prompts; evicted experts are pre-faulted back in. The RAM-floor trimmer releases pages. All of this is Windows-specific (no-op stubs elsewhere).
- **Async:** one blocking compute stream (`Kernels`). An optional private non-blocking stream exists for a side model such as TTS running beside the LLM (`load_with(private)`). A non-blocking upload stream with events. Mapped host memory for the router handshake. A spin-wait host loop.
- **Buffer reuse:** per-session preallocated scratch (`GpuSession`, `:9803–9847`), host scratch (`MoeHost`, `:6706–6722`), pinned table and sum buffers reused per layer, and a weight arena on the VMM APIs.
- **Scheduling and concurrency:** **one request at a time.** Generation runs on the model thread, with one OS thread per HTTP connection (`server.rs:1–6`; `docs/usage.md`: "Requests run one at a time"). There is **no continuous batching**; batching is used only for prompt prefill and speculative verify.
- **Multi-model:** model switching via `/api/models/load` drops one model and loads another, returning 503 during the switch. A "call model" can be kept beside the chat model when both fit (`Plan`, `server.rs:43–60`; `docs/usage.md`). Kernels can be shared between models (`share_kernels`, `cuda.rs:8600`).
- **Warm models:** the kernel cubin cache on disk. The model stays loaded in the server.
- **Out-of-core:** MoE experts can exceed RAM (they are re-read from the file). The Qwen3-Coder-Next 80B IQ2 example ran with 16 GB of RAM [DOC].

---

## 7. Other

- **OpenAI-compatible server [IMPL]** (`src/server.rs`; `docs/usage.md:55–96`):
  - `POST /v1/chat/completions` and `/v1/completions`, streamed over SSE, with `stream_options.include_usage`, plus `GET /v1/models`, `/v1/audio/speech` (TTS) and `/v1/audio/transcriptions` (Whisper).
  - **Tool calls:** the tools are rendered into the prompt in each model family's format and the model's text is *parsed after the fact* into `tool_calls` (`server.rs:1816–1967`). Supported formats: Qwen `<tool_call>`, Qwen3-Coder XML `<function=…>`, and GLM XML.
  - Other request fields: `reasoning_format` (thinking sent as `reasoning_content`) and `chat_template_kwargs.enable_thinking` / `preserve_thinking`.
  - **No JSON mode, no `response_format`/json_schema, no grammar or constrained decoding** ("Constrained decoding for tool calls" is a roadmap item [TODO]). No logprobs and no `n > 1`.
  - Chat templates are **hard-coded per family** (`ChatFormat::detect`, `main.rs:1222–1300`: ChatML/Qwen3, Qwen3-Coder, GLM-4, Mistral `[INST]`, Llama 3). There is no Jinja engine.
  - Many private `/api/*` endpoints serve the desktop agent: tools, MCP, plugins, skills, schedules, downloads, nightly LoRA, memory, chats.
- **Tokenizer [IMPL]:** a hand-written byte-level BPE (`src/tokenizer.rs`) with GPT-2, Qwen2, GLM-4/Llama-3 and Qwen3.5 pre-tokenizer splits implemented by hand (no regex crate) and literal special-token matching. **Only `gpt2`-type vocabularies** are supported.
- **Diagnostics and metrics:**
  - `GHOST_INFER_PROFILE` (per-op timing), `GHOST_INFER_MOE_STATS` (hit/miss/wait/CPU/route timings, `moe_stats_take`, `cuda.rs:10377–10457`), `GHOST_INFER_MOE_TRACE`, `GHOST_INFER_MOE_CHECK` (GPU vs CPU expert diff), `GHOST_INFER_LOAD_TIMES`, `GHOST_INFER_KERNEL_INFO` (registers and spills).
  - `GET /api/speed`, `/api/progress` (disk-wait progress), `/api/system`, and a terminal `monitor` (`src/monitor.rs`).
  - Accuracy tooling: `scripts/kld.py`, `golden.ps1`, `accuracy.ps1`, `check_dequant.py`, and `GHOST_INFER_EXACT=1` reference mode.
- **Training and adaptation:**
  - Runtime LoRA in llama.cpp's GGUF adapter format, applied as f32 `B·(A·x)` on top of quantized weights (`src/lora.rs:1–8`; `lora_a`/`lora_b` kernels) [IMPL].
  - "Sleep training": nightly QLoRA in Python with `torch`, `transformers`, `peft` and `bitsandbytes` (`scripts/nightly/train.py:20–22`), launched by the server (`src/server/nightly.rs`) [EXP; the README calls it experimental].
- **Hadamard-folded weights** (`src/hadamard.rs`, `prism.hadamard` metadata) and ternary Q2_0/PTQ1_0 kernels for PrismML "Bonsai" models [IMPL, niche].

---

## 8. Benchmarks (`docs/benchmarks.md`, verbatim figures)

**Hardware:**

| | |
|---|---|
| GPU | RTX 2060 SUPER 8 GB (Turing sm_75), driver 577.00 |
| CPU | Ryzen 5 3600, 6 cores / 12 threads |
| RAM | 24 GB DDR4-3200 (3×8 GB) since 2026-11-11; 16 GB DDR4-2133 earlier |
| Storage | 4B/8B models on a USB 3.0 HDD; the 30B on NVMe |
| OS | Windows 10 22H2 |

**Engines:** ghost-infer 0.4.0, llama.cpp b11747 (CUDA 12.4), Ollama 0.40.13.

**Dense, GuideLLM 0.8.1 synchronous, Qwen3 8B Q4_K_M (5.0 GB).** Columns are ghost-infer / llama.cpp (1 user) / llama.cpp (defaults) / Ollama.

| Workload | Metric | ghost-infer | llama.cpp (1 user) | llama.cpp (defaults) | Ollama |
|---|---|---|---|---|---|
| Chat (256→128) | gen tok/s | 70.3 | 64.8 | 64.7 | 66.0 |
| Chat | prompt tok/s | 905 | 1,366 | 1,257 | 1,002 |
| Chat | TTFT, ms | 292 | 193 | 210 | 264 |
| Chat | whole request, s | 2.11 | 2.16 | 2.17 | 2.19 |
| Long (2,048→256) | gen tok/s | 61.3 | 61.6 | 61.6 | 62.1 |
| Long | prompt tok/s | 1,490 | 1,455 | 1,343 | 1,327 |
| Long | TTFT, ms | 1,380 | 1,413 | 1,531 | 1,549 |
| Long | whole request, s | 5.56 | 5.55 | 5.67 | 5.65 |

Engine settings: llama.cpp `-ngl 99 -c 8192 --chat-template chatml`, with "1 user" adding `-np 1 --cache-ram 0`. Ollama runs with defaults. ghost-infer uses `serve --gpu` (`scripts/bench-engines.ps1:100–113`).

**Long contexts** (`bench --no-lookup` vs `llama-bench -fa 1 -d n`), generation tok/s:

| Model | Engine | 256 | 2K | 4K | 8K |
|---|---|---|---|---|---|
| 4B | ghost-infer | 118.2 | 111.6 | 98.5 | 80.4 |
| 4B | llama.cpp | 107.5 | 101.5 | 94.8 | 84.0 |
| 8B | ghost-infer | 73.3 | 70.6 | 65.1 | 56.5 |
| 8B | llama.cpp | 67.1 | 63.8 | 61.1 | 56.3 |

**MoE larger than the GPU** (24 GB RAM; seven prompts, greedy, 256 tokens; median of 2 rounds). llama.cpp runs `--n-cpu-moe 24` (picked by a llama-bench sweep over 16–48), `-c 4096 -np 1 --cache-ram 0`; ghost-infer runs `--ctx 4096` (`scripts/bench-readme.ps1:136–161`).

| Model | ghost-infer | llama.cpp | Ollama |
|---|---|---|---|
| Qwen3.6-35B-A3B i1-Q3_K_M (16.8 GB), median tok/s | 80.5 (range 76–87) | 39.5 (38–40) | 34.7 (34–35) |
| Qwen3-30B-A3B-Instruct-2507 Q3_K_M (13.7 GB), median tok/s | 68.7 (range 50–81) | 29.5 (27–30) | 26.9 (26–27) |
| 2K-paste prefill, Qwen3.6 (tok/s) | 601 | 396 | 455 |
| 2K-paste prefill, Qwen3-30B (tok/s) | 446 | 161 | 515 |

- Short-prompt TTFT is about 0.6 s on the others vs 0.9–1.0 s on ghost-infer.
- Old numbers (16 GB DDR4-2133, v0.3.0): 30B 38.0 / 23.7 / 21.7; 35B 45.3 / 25.1 / 26.1.
- The `bench` tool shows about 100 tok/s because its repeated-sentence prompt is the cache's best case, as the doc itself admits.

**Draft speculation, Qwen3 8B + Qwen3-0.6B Q8_0 (greedy):**

| Prompt | Without draft | With draft | Acceptance |
|---|---|---|---|
| Prime-checking function | 69.0 | 106.0 | 81% |
| Printing press | 69.1 | 80.7 | 55% |
| Why the sky is blue | 68.7 | 70.1 | 43% |

**Misc:**
- SmolLM2-135M vs Ollama 0.22.1: generation 277 vs 168 tok/s.
- CPU-only 8B: ghost-infer is slower (prompt 9.4 vs 18.2 tok/s, generation 5.2 vs 5.9).

**Is it apples-to-apples?** Partly.
- **Fair:** same GGUF file, same machine, one run, two rounds averaged, the llama.cpp `--n-cpu-moe` setting tuned, and the KV-type difference disclosed. MoE lookup is off by default, so the MoE numbers aren't inflated by speculation. The long-context table uses `--no-lookup`.
- **Caveat 1, KV cache:** ghost-infer uses its **int8 KV cache** while llama.cpp and Ollama use f16. That halves attention bandwidth in decode. llama.cpp's `-ctk q8_0 -ctv q8_0` was not tried.
- **Caveat 2, lookup in dense serving numbers:** in the dense GuideLLM table, ghost-infer ran with **prompt-lookup speculation enabled** (the default for `serve --gpu`). Its adaptive pacing makes this mostly neutral on synthetic text, but it is a speculative path that llama.cpp did not get.
- **Caveat 3, MoE placement:** this is static (llama.cpp's whole layers of experts on the CPU) vs dynamic (ghost-infer's VRAM cache tuned to temporal locality). The comparison is legitimate as "how users run it", but llama.cpp's `-ot` per-tensor overrides and thread or batch tuning weren't explored. Thread count and flash-attention were left at defaults in the server runs. The test hardware has a weak CPU (6-core Zen 2) and 3-DIMM DDR4, which makes CPU-side experts especially expensive and favors a design that moves work to the GPU.
- **Caveat 4, workload:** greedy, 256-token outputs, single user; numbers swing with expert locality (50–81 on the 30B).
- **Caveat 5, quant format:** only Q3_K / IQ2 experts are cacheable on the GPU, so the MoE results do not transfer to Q4_K_M MoE files.

**Likely sources of the MoE speedup:** (1) about 72–88% of expert picks served from VRAM thanks to frequency-gated LRU, vs llama.cpp's fixed ~50% of layers' experts on the CPU; (2) per-layer CUDA graphs with GPU top-k and a zero-copy mapped-memory handshake, which removes launch, sync and memcpy overhead per layer; (3) GPU and CPU experts computed concurrently, with the shared expert overlapped; (4) a low-latency spinning, pinned CPU pool; (5) Q3_K kept 3-bit on the GPU, so more experts fit.

---

## 9. Apple Silicon applicability

**Does it build or run on macOS?** By inspection, **no, at this SHA.**
- Several functions import `std::os::windows::process::CommandExt` **without a `#[cfg(windows)]` gate**: `src/tools.rs:601, 650, 837`; `src/server/download.rs:44`; `src/server/mcp.rs:163`. These modules are compiled unconditionally (`main.rs:21`, `mod tools`; `server.rs:20–22`), so `cargo build` on macOS or Linux would fail with an unresolved `std::os::windows` path.
- Even with those patched, the result would be **CPU-only and scalar**:
  - the GPU `os` stub returns `None` for `nvcuda.dll`;
  - there is no NEON path (`has_avx2()` returns false on aarch64);
  - the RAM floor, prefetch and thread pinning are Windows-only;
  - paths assume `%LOCALAPPDATA%`, and the agent tools use PowerShell and `curl.exe`.
- The desktop app uses WebView2/wry on Windows.

**Discrete-GPU or PCIe-specific techniques (do not transfer to unified memory):**
- The VRAM expert cache, slot uploads over PCIe, double-buffered pinned staging, the upload stream and "release RAM after upload". On unified memory every expert is already GPU-addressable, so the cache collapses.
- The CPU-vs-GPU expert split. On an M-series chip CPU and GPU share one DRAM bandwidth pool, so running misses on the CPU adds little bandwidth (at most some compute parallelism).
- The mapped-host-memory router handshake. It is unnecessary with shared memory, although the idea of keeping routing on the GPU to avoid host round-trips still holds.
- NVRTC, dp4a, `mma.sync`/`ldmatrix` kernels and CUDA graphs. The conceptual counterparts are Metal kernels, MLX `mx.compile`, and indirect command buffers.

**Hardware-agnostic techniques (worth porting):**
1. **Prompt-lookup speculation with the `Pace` controller** (`src/lookup.rs`, pure Rust, about 280 lines plus tests): a pair-index n-gram matcher, a cost model fitted online, bucketed acceptance priors, and a back-off. Especially relevant for coding and agent edits.
2. **Exact greedy verify** through batch-invariant kernels (fixed reduction order and explicit rounding). The principle transfers to Metal/MLX kernels if their verify-batch arithmetic matches decode.
3. **Exact sampled acceptance** for single-token drafts (`Sampler::accept`).
4. **Expert-cache admission policy**: recency eviction gated by an exponentially decayed pick frequency, prompt picks excluded, and a per-token upload cap. On unified memory it maps to *SSD → RAM residency*: which experts to keep wired or paged when the model exceeds RAM. It comes with layer-ahead coalesced prefetch (`Prefetcher`), an LRU working-set trimmer (`Trimmer`, `madvise` analogue), and trace capture for offline replay (`GHOST_INFER_MOE_TRACE`).
5. **Prefix "openings" kept in host RAM** for agent and subagent system prompts, plus recurrent-state snapshots for DeltaNet models.
6. **KV growth in 4K steps** so that unused context memory serves other uses. An **int8 per-(pos, head) KV cache**, and a **Hadamard-rotated 4-bit KV cache** (rotation roughly halves the 4-bit error, per the comment at `cuda.rs:73–79`).
7. Prompt-batch MoE grouping by expert (gather, GEMM, scatter), and running small verify batches token-wise for MoE.

---

## 10. Security notes

- **No telemetry found.** There is no analytics or phone-home code.
- **Outbound network** (all through external `curl.exe`/`curl`, since there is no TLS library):
  - model downloads restricted to `https://huggingface.co/` (`src/server/download.rs:27–56`);
  - agent web tools fetch arbitrary URLs and DuckDuckGo HTML search (`src/tools.rs:831–871`);
  - skill installs download from GitHub (`codeload.github.com` / `raw.githubusercontent.com`) and unpack with `tar` (`src/server/skills.rs:215–260`).
  - `monitor.rs` connects only to the local server.
- **Code execution surfaces** (desktop-agent features, not the inference core):
  - an agent shell runs PowerShell with `-ExecutionPolicy Bypass` (`src/tools.rs:599–613`);
  - MCP servers are spawned from `mcp.json`, and the server can **import Claude Desktop's `mcpServers` config** (`src/server/mcp.rs:158–185, 472–480`);
  - Python plugins (`src/server/plugins.rs:506`) and nightly Python training (`src/server/nightly.rs:66`) also run;
  - scheduled autonomous prompts use only "always allowed" tools (`src/server/schedule.rs:1–8`).
- **HTTP exposure:**
  - The server binds `127.0.0.1:8080` by default; `--host` can expose it.
  - `/v1/*` has **no authentication** and returns `Access-Control-Allow-Origin: *` (`server.rs:991`), so any web page the user visits can use the local model.
  - Private `/api/*` routes are gated by a loopback peer, a `Host` allowlist (a DNS-rebinding defense), an `Origin` match and an `X-Ghost-Token` (`tools_allowed`, `server.rs:1162–1177`). The token is embedded in the chat page and derived from `RandomState` (OS-seeded SipHash keys) mixed with time and pid (`new_token`, `:1146–1158`). That is acceptable but not an explicit CSPRNG.
- **unsafe volume:** about 245 `unsafe` occurrences. Most are in `src/cuda.rs` (120: FFI, raw device pointers, `transmute` of `GetProcAddress` results), `src/quant.rs` (57: SIMD intrinsics), `src/sysinfo.rs` (29) and `src/pool.rs` (7: a hand-rolled job handoff with `transmute` of a closure lifetime, `pool.rs:75`).
- **Build scripts:** there is no `build.rs` and nothing is downloaded at build time. `scripts/build-installer.ps1` needs Inno Setup locally and does not download. The cubin cache under `%LOCALAPPDATA%` is loaded without an integrity check beyond a hash-named file; a local attacker with write access there could plant GPU code (low risk).
- **Python and pip:** the training path pulls the torch/transformers/peft/bitsandbytes ecosystem; this is a user-managed install.
- **Provenance:** a 3-week-old, single-author project with a very large feature surface (agent, MCP, plugins, voice, training) beyond inference. Treat it as research reference code, not a dependency.
