# Runtime Landscape — Running >RAM MoE / Large Models on Apple Silicon (M1 Pro, 32 GB)

**Phase-A research for `esh`.** Target hardware: **M1 Pro, 32 GB unified memory, external SSD, macOS.**
Goal: prefer **extending a proven runtime** over writing custom Metal kernels. Focus: SSD-backed expert streaming + CPU/GPU overlap for MoE models that exceed RAM.

Labels: **[FROM-DOCS]** = stated in official docs / source / flag help; **[INFERRED]** = my analysis/synthesis, needs validation on the box.
Date: 2026-10-07. Knowledge cutoff Jan 2026 — verify versions against HEAD before committing.

---

## 0. The core constraint (read first)

Apple Silicon has **unified memory**: CPU and GPU share one physical pool. On a 32 GB M1 Pro there is **no separate VRAM to "offload to CPU RAM" into** — "keep experts on CPU" saves almost nothing in bytes, because CPU RAM and GPU RAM are the same bytes. **[INFERRED]** This is the single most important fact and it inverts most of the CUDA playbook:

- On CUDA/discrete GPUs, "MoE expert offload to CPU" means *move expert tensors out of the scarce 12–24 GB VRAM into abundant 64–128 GB system RAM*. That is a real win.
- On a 32 GB Mac, the scarce resource is the **whole 32 GB pool** (minus ~6–10 GB for OS/wired). The only way to run a model whose *weights* exceed that pool is to **stream weights from SSD** (mmap page cache or explicit layer/expert streaming), not to "offload to CPU."

Therefore, for a **>RAM MoE on M1 Pro**, the techniques that actually matter are: **mmap + OS page cache eviction (llama.cpp default)**, **explicit SSD expert/layer streaming**, **aggressive quantization to shrink the working set**, and **KV-cache quantization**. CPU/GPU "overlap" on Mac means overlapping **SSD I/O with Metal compute**, not CPU-matmul with GPU-matmul. **[INFERRED]**

External-SSD note: sequential read bandwidth (Thunderbolt/USB SSD ≈ 1–3 GB/s; internal NVMe ≈ 3–6 GB/s) is the binding throughput limit for any streaming approach. At ~2 GB/s an external SSD, touching ~15 GB of experts per token puts a hard floor near ~7–8 s/token — streaming only wins when per-token *active* bytes are small (sparse MoE) and hot experts stay resident. **[INFERRED]**

---

## 1. llama.cpp / GGUF — what it can do TODAY on Metal for a >RAM MoE

Repo: https://github.com/ggml-org/llama.cpp • Docs/flags: https://github.com/ggml-org/llama.cpp/tree/master/tools/server • man pages: https://manpages.debian.org/unstable/llama.cpp-tools/llama-server.1.en.html

### 1a. MoE expert placement flags **[FROM-DOCS]**
- `--cpu-moe` / `-cmoe` — "keep all Mixture of Experts (MoE) weights in the CPU." (man page)
- `--n-cpu-moe N` / `-ncmoe N` — "keep the Mixture of Experts (MoE) weights of the first N layers in the CPU." (man page) Env: `LLAMA_ARG_N_CPU_MOE`.
- `--override-tensor <pattern>=<buffer type>` / `-ot` — "override tensor buffer type," format `<tensor name pattern>=<buffer type>,...`. Env: `LLAMA_ARG_OVERRIDE_TENSOR`. (man page / server README)

The canonical community recipe on CUDA is `-ngl 99` (all layers to GPU) **plus** `-ot` regex that forces expert FFN tensors back to CPU, e.g. keep attention + shared weights on GPU and send the big per-expert FFN matrices to CPU:
```
-ngl 99 -ot "\.ffn_(up|down|gate)_exps\.=CPU"
```
or, newer and simpler, `-ngl 99 --n-cpu-moe 30` (keep first 30 layers' experts on CPU). The GGUF tensor names for experts are `blk.N.ffn_{up,down,gate}_exps.weight`; the `_exps` suffix is what the regex targets. **[FROM-DOCS]** for flags; the specific regex is the widely-documented idiom (e.g. https://dev.to/someoddcodeguy/understanding-moe-offloading-5co6). `-ot` takes a buffer-type name on the right (`CPU`, or a specific GPU device id); multiple rules are comma- or repeat-separated and matched top-to-bottom. **[FROM-DOCS]**

**On Metal specifically:** these flags *work* but the byte-saving rationale mostly evaporates (unified memory, §0). What `-ot ...=CPU` **does** still change on Mac: it forces those tensors to be computed by the **CPU/Accelerate backend** rather than the Metal backend, which changes *where compute happens* and can let the Metal residency set stay smaller. It does **not** give you a VRAM vs RAM split. **[INFERRED]** The practical Mac lever is instead `-ngl` + mmap (below).

### 1b. Partial GPU offload — `-ngl` **[FROM-DOCS]**
- `-ngl N` / `--n-gpu-layers N` / `--gpu-layers` — "max. number of layers to store in VRAM, either an exact number, 'auto', or 'all'." On Metal, `-ngl 0` runs everything on CPU; any `-ngl>0` runs those layers through the Metal backend. For a model that fits in unified memory you normally use `-ngl 99`/`all`.

### 1c. mmap + weight streaming — the real Mac >RAM mechanism **[FROM-DOCS]/[INFERRED]**
- mmap is **ON by default**. `--no-mmap` disables it (forces a full load / lock into RAM). `--mlock` locks pages resident. (man page)
- With mmap on, llama.cpp maps the GGUF file; the **OS page cache** pulls pages from SSD on demand and evicts under pressure. This is the de-facto "weight streaming from SSD" path on macOS: **you can `mmap` a GGUF larger than RAM and it will run**, with the kernel paging expert/layer tensors in and out. There is **no explicit llama.cpp "expert prefetcher" or LRU expert cache** — it relies entirely on the OS pager. **[INFERRED, HIGH CONFIDENCE]**
- Consequence for MoE: because MoE touches a *different, data-dependent subset* of experts each token, the page cache thrashes — the working set is effectively "all experts that any recent token used." Throughput collapses to SSD-read-bound once total touched experts > free RAM. This is exactly the gap a custom expert cache/prefetcher would fill. **[INFERRED]**

### 1d. KV-cache quantization **[FROM-DOCS]**
- `--cache-type-k` / `-ctk` and `--cache-type-v` / `-ctv`. Allowed: `f32, f16, bf16, q8_0, q4_0, q4_1, iq4_nl, q5_0, q5_1` (default `f16`). Typical long-context setup: `-ctk q8_0 -ctv q5_1` or `q4_0`. Halving/quartering KV frees unified memory for weights/experts.

### 1e. Flash Attention **[FROM-DOCS]**
- `--flash-attn` with `'on' | 'off' | 'auto'` (default `auto`). Metal has a Flash-Attention kernel; FA is generally required to get the quantized-KV types above to run efficiently and reduces attention memory.

### 1f. Speculative decoding (draft model) **[FROM-DOCS]**
- `--model-draft` / `-md` / `--spec-draft-model` — "draft model for speculative decoding (default: unused)."
- Draft control: the old `--draft/--draft-n/--draft-max` was removed; use `--spec-draft-n-max` (and ngram variants `--spec-ngram-mod-n-max`). (man page) `llama-server` and `llama-speculative` support it. Works on Metal. Caveat: on a memory-starved box the **draft model also consumes unified memory + its own KV**, so speculative decoding trades memory for latency. **[INFERRED]**

### 1g. Metal backend specifics **[FROM-DOCS]/[INFERRED]**
- First-class Metal backend (ggml-metal), unified-memory aware, zero-copy CPU↔GPU buffers. MoE matrix-vector / top-k routing kernels exist for the common GGUF quants (Q2_K…Q8_0, IQ4_NL, etc.). Build default on macOS; `GGML_METAL=ON`.
- There is a Metal buffer-size ceiling (`maxBufferLength`, ~ tied to recommended working-set); very large single tensors must be split. **[INFERRED]**

### 1h. Bottom line for llama.cpp on Mac
It is the **most mature, Metal-native option that already runs a >RAM GGUF MoE today** via mmap — unattended, no code. But it has **no MoE-aware expert cache/prefetch**; >RAM MoE perf is dictated by OS paging and SSD bandwidth. The `-ot`/`--n-cpu-moe` flags are CUDA-shaped and give little on unified memory. **This is the best base to extend** (C++/ggml, add an expert residency manager + prefetch on top of the existing mmap/Metal path). **[INFERRED]**

---

## 2. MLX / mlx-lm — what control it gives for >RAM models

Repos: https://github.com/ml-explore/mlx • https://github.com/ml-explore/mlx-lm • Memory API docs: https://ml-explore.github.io/mlx/build/html/python/_autosummary/mlx.core.set_memory_limit.html

### 2a. MoE support **[FROM-DOCS]**
mlx-lm ships MoE model implementations (Mixtral, Qwen-MoE / Qwen3-MoE, DeepSeek-V2/V3, GPT-OSS, etc.). MoE is expressed with a fast gather-based `mx.gather_mm` / quantized gather matmul path, so experts run natively on Metal.

### 2b. Quantization (4/8-bit, mixed) **[FROM-DOCS]**
- `mlx_lm.convert --model <hf> -q` → 4-bit by default; `--q-bits {2,3,4,6,8}`, `--q-group-size`. Mixed-precision quantization recipes supported (per-layer bit choice). Python: `mlx_lm.convert(..., quantize=True)`.

### 2c. KV-cache quantization **[FROM-DOCS]**
- `mlx_lm.generate --kv-bits {8,4,...} --kv-group-size N --quantized-kv-start N` — `--quantized-kv-start` "only quantizes caches with at least N tokens" (skips short prefills). (`generate_step` accepts `kv_bits`, `kv_group_size`, `quantized_kv_start`.) https://deepwiki.com/ml-explore/mlx-lm/7.2-speculative-decoding

### 2d. Speculative decoding **[FROM-DOCS]**
- `mlx_lm.generate --draft-model <path> --num-draft-tokens N`. Draft model proposes, target verifies in one pass. Supported in CLI + server. (same deepwiki page)

### 2e. Rotating / bounded KV **[FROM-DOCS]**
- `--max-kv-size n` → rotating (ring-buffer) KV cache, caps attention memory for long contexts. Prompt caching: `mlx_lm.cache_prompt` + `--prompt-cache-file`.

### 2f. Memory limits / wired limit — the Mac-specific knobs **[FROM-DOCS]**
- `mx.set_memory_limit(limit:int) -> int` — soft guideline for max bytes during graph eval; returns previous. Default on Metal = **1.5× device recommended working-set size**; exceeding it with no RAM left raises.
- `mx.set_cache_limit(limit)` — caps MLX's internal buffer cache (bytes it holds for reuse); set to 0 to free aggressively.
- `mx.set_wired_limit(limit)` — caps **wired (non-pageable) memory**; raising it (up to the system wired limit, tunable via `iogpu.wired_limit_mb` sysctl) keeps more resident on GPU and avoids paging stalls. `mx.metal.device_info()` / `mx.get_active_memory()` / `mx.get_peak_memory()` for introspection.

### 2g. Partial offload / streaming / lazy loading **[FROM-DOCS]/[INFERRED]**
- **Lazy evaluation + lazy weight loading:** `mx.load` memory-maps safetensors; arrays are lazy and only materialize when evaluated (`mx.eval`). So weights *can* be mmap-backed and paged by the OS like llama.cpp. **[FROM-DOCS for lazy/mmap; INFERRED that this yields >RAM paging.]**
- **No built-in layer/expert SSD-streaming scheduler.** mlx-lm has no equivalent of AirLLM's explicit per-layer disk streaming nor an expert LRU cache. For >RAM you rely on (a) quantizing small enough to fit, or (b) OS paging of the mmap, or (c) building your own streaming on top of `mx.load`/lazy arrays. **[INFERRED]**
- MLX is designed around everything living in unified memory; it has **no "offload tensor to CPU vs GPU" split** because there is one pool (consistent with §0).

### 2h. Bottom line for MLX
Best-in-class **quantization quality, KV-quant, speculative decoding, and fine memory control** (wired/cache/limit) on Metal, with clean Python to build on. MoE runs natively and fast *when it fits*. For **>RAM** it has lazy/mmap loading but **no expert streaming engine** — that is custom work. Strong candidate if `esh` wants to **build the streaming layer in Python/MLX** rather than C++. **[INFERRED]**

---

## 3. Specialized projects — technique / Mac support / maturity / license

| Project | Technique | Runs on Metal/Mac? | Maturity | License |
|---|---|---|---|---|
| **ktransformers** (kvcache-ai) | Heterogeneous CPU/GPU MoE offload; keeps attention/shared on GPU, routes expert FFNs to CPU with AMX/optimized CPU kernels; expert placement rules; GGUF+safetensors | **No** — CUDA (+ Intel AMX) centric, Linux/Windows; no Metal backend | High (DeepSeek-V3/R1 on 1 GPU + RAM is its headline) | Apache-2.0 |
| **PowerInfer** (SJTU-IPADS) | Hot/cold **neuron** split via activation sparsity (ReLU/ProSparse models); hot neurons GPU-resident, cold on CPU; built on llama.cpp | **Partial** — M-chip support is **CPU-only, "not significant" speedup per README**; sparse **Metal backend "coming soon"** (unreleased) | Research-grade, less active | MIT |
| **PowerInfer-2** (SJTU-IPADS) | Smartphone (Android/Qualcomm) MoE up to 47B > device RAM; neuron-cluster scheduling, NPU+CPU, I/O-compute pipelining, flash-storage streaming | **No** — Android/Qualcomm NPU; paper + limited release, not macOS | Research prototype | (paper; code limited) |
| **AirLLM** | **Layer-by-layer disk streaming**: one transformer layer on device at a time, rest streamed from disk; for MoE streams only routed experts | **Yes** — "macOS Apple Silicon support via **MLX backend**" per README | Usable but slow (optimized for *fitting*, not speed); throughput very low | Apache-2.0 |
| **Strata** (github `mach10x/strata`) | Expert streaming across tiers: hottest experts→GPU, all experts→RAM, remainder→CPU, lookup tables→**SSD**; + speculative decoding; built on **llama.cpp/ggml** | **No** — explicitly NVIDIA+AMD (Windows/Linux); no Metal | Early (small repo, active commits) | MIT |
| **fastllm** | CPU+GPU hybrid inference, custom quant; some MoE | Primarily CUDA/x86; **Mac/Metal weak-to-absent** | Moderate (CN community) | Apache-2.0 |
| **exllama / v2 / v3** | Highly optimized GPTQ/EXL2 quant kernels | **No** — **CUDA-only** (some ROCm); no Metal | High on NVIDIA | MIT |
| **llama.cpp MoE-streaming forks** | Various `-ot`/offload experiments; mostly folded upstream into `--n-cpu-moe`/`-ot` | Inherit llama.cpp Metal, but forks target CUDA VRAM split | Varies | MIT |
| **PiKV** / **Stratum** (papers) | KV-cache mgmt for MoE / 3D-DRAM tiered expert serving | No (research / datacenter HW) | Research | varies / n/a |

**Key reads:** PowerInfer paper https://arxiv.org/pdf/2312.12456 • PowerInfer-2 https://arxiv.org/pdf/2406.06282 • AirLLM https://github.com/lyogavin/airllm • Strata https://github.com/mach10x/strata • ktransformers https://github.com/kvcache-ai/ktransformers

**Takeaway:** Every project that *implements* real SSD/expert streaming (ktransformers, Strata, PowerInfer-2, exllama) is **CUDA/NVIDIA/Android — not Metal.** The only ones that run on Apple Silicon are **llama.cpp** (OS-paging only, no expert cache), **MLX** (no streaming engine), and **AirLLM** (slow, MLX-backed layer streaming). **There is no existing Metal-native MoE SSD-streaming engine with hot-expert caching — that is the white space.** **[INFERRED, HIGH CONFIDENCE]**

---

## 4. Technique primers (with Apple-Silicon feasibility)

1. **Mixed quantization** — per-layer/per-tensor bit allocation (e.g. 2–3 bit experts, 4–6 bit attention/shared, 8-bit sensitive layers). **Feasible now**: GGUF k-quants/IQ + MLX `--q-bits`/mixed recipes. *Highest-leverage lever on 32 GB* — shrinking the working set so a model *fits* beats any streaming. **[FROM-DOCS]**
2. **KV-cache quantization** — K8/V4 typical; cuts attention memory 2–4×. Feasible now: llama.cpp `-ctk/-ctv`, MLX `--kv-bits`. **Placement** of KV (keep on GPU vs page) is moot on unified memory. **[FROM-DOCS]**
3. **Flash Attention** — fused attention, less memory + faster long context. Metal kernel exists (llama.cpp `--flash-attn`; MLX `scaled_dot_product_attention`). **Feasible now.** **[FROM-DOCS]**
4. **Speculative decoding (draft model)** — small draft proposes, big verifies; 1.5–2.5× latency win *if acceptance high*. Feasible now (llama.cpp `--model-draft`; MLX `--draft-model`). On 32 GB, **costs memory** (2nd model + KV); only worth it if the pair still fits. **[FROM-DOCS]**
5. **MTP / multi-token prediction** — model natively predicts several tokens/step (DeepSeek-V3 style), a built-in draft. Feasible if runtime supports the MTP head; llama.cpp/MLX support is model-dependent and partial. **[INFERRED]**
6. **Expert prefetch / caching (LRU/LFU/router-prob)** — predict next experts from router logits and prefetch from SSD; keep a bounded resident cache keyed by access frequency. **Not available in any Mac runtime today** — this is the main custom build. Feasible to implement on top of llama.cpp mmap or MLX lazy load. **[INFERRED]**
7. **Dynamic expert residency** — keep top-k globally-hot experts pinned (wired) in unified memory, stream the long tail. Pair with `mx.set_wired_limit` (MLX) or a custom ggml buffer pool. **Custom.** **[INFERRED]**
8. **Hot-expert caching** — special case of (6)/(7): exploit skewed expert-usage distributions (power law) so a small resident set covers most tokens. Strongly dependent on model's routing skew — **must profile per model.** **[INFERRED]**
9. **Adaptive context sizing** — shrink max context / use rotating KV (`--max-kv-size`) to reclaim memory for weights when prompts are short. Feasible now. **[FROM-DOCS]**
10. **Selective layer placement (`-ngl`, `-ot`, `--n-cpu-moe`)** — on CUDA a VRAM/RAM split; on unified memory it only moves *compute* between Metal and CPU/Accelerate backends, not bytes. Use sparingly on Mac; main value is forcing a few ops to CPU to shrink the Metal residency set. **[INFERRED]**

---

## 5. Bottom line — best starting point for a >RAM MoE on M1 Pro TODAY

**Start from llama.cpp (Metal) as the base; use MLX as the fast-iteration / quantization lab.**

**What works out-of-the-box today (no custom code):**
- A heavily quantized MoE (2–4 bit, e.g. IQ2/IQ3/Q4_K) that **fits in ~22–26 GB** of the 32 GB pool runs *fast and natively* on Metal in both llama.cpp and MLX — this is the sweet spot and should be the default target. **[INFERRED]**
- A GGUF MoE **larger than RAM** already *runs* in llama.cpp via default **mmap** (OS pages experts from SSD) — correct output, but throughput degrades to SSD-bound and thrashes because there is **no expert-aware caching**. `--n-cpu-moe`/`-ot` exist but give little on unified memory. KV-quant (`-ctk/-ctv`), Flash-Attn, and speculative decoding all work on Metal today. **[FROM-DOCS + INFERRED]**
- MLX gives the best quantization quality, `--kv-bits`, `--draft-model`, and real memory governors (`set_memory_limit` / `set_wired_limit` / `set_cache_limit`), but has **no streaming engine** either. **[FROM-DOCS]**

**Where custom work is needed (and how much):**
- **The gap is a Metal-native, MoE-aware SSD expert-streaming + hot-expert cache with I/O↔compute overlap.** No existing Mac runtime has it; every runtime that does (ktransformers, Strata, PowerInfer-2, exllama) is CUDA/Android. **[INFERRED, HIGH CONFIDENCE]**
- **Recommended path (medium effort, weeks not months):** extend **llama.cpp/ggml** — add (a) a bounded **resident-expert cache** (LRU/LFU keyed on router activations), (b) **router-probability prefetch** that issues SSD reads for likely-next experts while the current layer computes on Metal, and (c) pinning of globally-hot experts. This reuses llama.cpp's mature Metal kernels, GGUF loader, and mmap plumbing — **no new Metal kernels required**, which satisfies the "prefer proven runtimes" constraint. **[INFERRED]**
- **Alternative (if Python/MLX ergonomics preferred):** build the same expert-residency/prefetch scheduler on MLX lazy-loaded weights; faster to prototype, but you inherit MLX's thinner MoE-streaming ecosystem and must manage buffers via `set_wired_limit`. **[INFERRED]**
- **Do NOT port** ktransformers/Strata/exllama — their value is CUDA kernels and VRAM/RAM splitting that don't map to unified memory. Mine them for the *scheduling ideas* (hot/cold expert tiering, prefetch) only. **[INFERRED]**
- **Validate before building:** profile the target model's **expert-usage skew** on real prompts (does a small hot set cover most tokens?) and **measure external-SSD sequential read bandwidth** — both determine whether streaming can ever beat "just quantize until it fits." **[INFERRED]**

---

### Source URLs
- llama.cpp server/CLI flags: https://manpages.debian.org/unstable/llama.cpp-tools/llama-server.1.en.html • https://github.com/ggml-org/llama.cpp
- MoE offload idiom (`-ot`, `--n-cpu-moe`): https://dev.to/someoddcodeguy/understanding-moe-offloading-5co6
- MLX memory API: https://ml-explore.github.io/mlx/build/html/python/_autosummary/mlx.core.set_memory_limit.html
- mlx-lm speculative decoding / KV-quant flags: https://deepwiki.com/ml-explore/mlx-lm/7.2-speculative-decoding • https://github.com/ml-explore/mlx-lm
- ktransformers: https://github.com/kvcache-ai/ktransformers
- PowerInfer: https://arxiv.org/pdf/2312.12456 • https://github.com/SJTU-IPADS/PowerInfer
- PowerInfer-2: https://arxiv.org/pdf/2406.06282
- AirLLM: https://github.com/lyogavin/airllm
- Strata (mach10x): https://github.com/mach10x/strata
- PiKV / Stratum (MoE KV / tiered serving, research): https://arxiv.org/pdf/2508.06526 • https://arxiv.org/pdf/2510.05245

> Version caveat: flag spellings (`--n-cpu-moe`, `--spec-draft-n-max`, `--kv-bits`) and MLX API shape move fast; confirm against the installed llama.cpp/mlx-lm `--help` on the box before wiring into `esh`.
