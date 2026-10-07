# Apple Unified Memory (UMA) and Large MoE/Sparse Inference on M1 Pro

**Phase-A research for `esh`**
**Target machine:** Apple M1 Pro, 32 GB unified memory, ~200 GB/s memory bandwidth, external ~2 TB SSD, macOS.
**Goal:** Determine how UMA changes the optimal architecture for running a 100B+ MoE model (with ~a few B active params/token) that exceeds RAM, using SSD-backed expert streaming + CPU/GPU concurrency.

**Claim labels:** `[FROM-DOCS]` = stated in vendor/official docs or source; `[INFERRED]` = reasoned from documented facts; `[THEORETICAL]` = model/estimate not directly measured here.

> Note on sources: several web-search hits returned arXiv IDs with impossible years (2601/2604/2607/2609…). Those look like fabricated/hallucinated search artifacts and are **not** cited. Only Apple docs, MLX docs/source, llama.cpp docs/issues, and identifiable engineering write-ups are used below.

---

## 0. Baseline numbers (anchor the whole analysis)

- M1 Pro unified memory bandwidth ≈ **200 GB/s** shared by CPU, GPU and ANE. `[FROM-DOCS]` (Apple positions M1 Pro at 200 GB/s; M1 Max 400, M1 Ultra 800.)
- Internal NVMe on M1 Pro ≈ 5 GB/s sequential; an **external** ~2 TB SSD is the streaming tier: Thunderbolt 3 / USB4 enclosure ≈ **2.5–3 GB/s** sequential, USB 3.2 Gen2 ≈ ~1 GB/s, and **random** 4K/page-sized reads are far lower. `[INFERRED]`
- Ratio that governs everything: **RAM is ~40–100× faster than the external SSD**, and ~15–25× faster than even the internal NVMe. `[INFERRED]`
- LLM **decode is memory-bandwidth-bound**, not compute-bound: `tok/s ≈ effective_bandwidth / bytes_read_per_token`. `[FROM-DOCS]`/`[THEORETICAL]` (widely documented; e.g. a 39 GB resident 70B at 400 GB/s ⇒ ~98 ms/token floor). ([sitepoint][sp], [starmorph][star])

The central consequence: **anything you stream from SSD per token is on the critical path of a bandwidth-bound loop whose "fast" tier is already only 200 GB/s.** The whole architecture is about keeping the per-token byte traffic in RAM and making SSD traffic rare, large, and prefetched.

---

## 1. PCIe copies vs UMA: how expert-streaming design changes

### The desktop (discrete-GPU) model
On a classic desktop, CPU RAM and GPU VRAM are **separate physical pools** connected by PCIe. A tensor the GPU needs must be copied host→device across PCIe (~16–32 GB/s for PCIe 4.0 x16, far below VRAM's ~1 TB/s). Expert-streaming there is a **three-hop** pipeline: SSD → host RAM → (PCIe) → VRAM, and "offloading an expert to CPU" means it physically lives in a different memory with a copy wall between the two processors. `[FROM-DOCS]` ([Apple resource storage overview][amd])

### The Apple UMA model
Apple GPUs "have a unified memory model in which the CPU and the GPU share system memory." A buffer with `MTLStorageMode.shared` "defines system memory that both the CPU and the GPU can access." `shared` is the **default** for buffers/textures on Apple GPUs. `[FROM-DOCS]` ([Apple: storage mode for Apple GPUs][apple-shared])

This removes the PCIe hop entirely:

- There is **one pool**. A tensor placed in a `shared` buffer is addressable by **both** CPU and GPU at the same physical address — no host↔device copy. `[FROM-DOCS]`
- MLX makes this explicit: "arrays live in unified memory"; you do not move data between devices, you only choose *which processor runs an op* via a `stream` argument (`mx.cpu` / `mx.gpu`), and MLX inserts cross-stream dependencies automatically. `[FROM-DOCS]` ([MLX unified-memory docs][mlx-um])

### So can `esh` keep experts in unified memory and dynamically pick CPU-vs-GPU without separate copies?

**Yes — this is exactly what UMA enables, and it is the single biggest architectural change vs desktop.** `[FROM-DOCS]`/`[INFERRED]`

- One resident copy of each expert, in a `shared` (or MLX unified) allocation, can be executed by **either** the GPU (Metal compute kernel) or the CPU (Accelerate/NEON) with no transfer. The routing decision ("run this cold expert on CPU while the GPU does shared layers") becomes a **scheduling** decision, not a data-movement decision. `[FROM-DOCS]` ([MLX unified-memory docs][mlx-um])
- In MLX this is literally one line: `mx.matmul(x, w, stream=mx.cpu)` vs `stream=mx.gpu`, on the *same* array. MLX reports ~2× from running a GPU-heavy op and a CPU-overhead-bound op concurrently on M1 Max. `[FROM-DOCS]` ([MLX unified-memory docs][mlx-um])

### The real constraints (what UMA does *not* make free)

1. **Residency / wired memory.** The GPU can only touch memory that is *resident* when a command buffer runs. Metal exposes a budget via `recommendedMaxWorkingSetSize` (≈75% of unified RAM by default), and the kernel caps how much can be **wired** (non-pageable) for GPU use. On a 32 GB machine the practical GPU-usable ceiling is ~21–24 GB out of the box. `[FROM-DOCS]`/`[INFERRED]` ([mehmetbaykar VRAM cap][baykar], [starmorph][star])
2. **Wired vs purgeable.** Wired memory is pinned and counts hard against the OS; too much wiring starves macOS and triggers instability. Purgeable/pageable memory can be reclaimed under pressure — good for a cold-expert cache, bad for anything on the per-token critical path (a reclaim becomes a fault). `[INFERRED]` ([Apple MTLStorageMode][amd])
3. **Page faulting.** `shared`/file-backed pages that are *not yet resident* fault in on first access. A GPU command buffer that touches many cold pages can stall and, on slow backing store, blow the **Metal command-buffer watchdog timeout** (observed with MLX models loaded from NFS/external volumes). This is the key hazard for cold-expert streaming. `[FROM-DOCS]` ([MLX issue #3803][mlx3803])
4. **`MTLResourceStorageMode` choice:** `shared` (CPU+GPU, the default, what experts should use), `private` (GPU-only, needs a blit to populate — wrong for CPU-executable experts), `memoryless` (tile memory, textures only — irrelevant). `[FROM-DOCS]` ([Apple: storage mode for Apple GPUs][apple-shared])
5. **mmap + GPU access** has an alignment contract (see §2): zero-copy GPU access to an mmap'd file requires page-aligned mapping wrapped via `makeBuffer(bytesNoCopy:)`. `[FROM-DOCS]` ([Apple makeBuffer(bytesNoCopy:)][nocopy])

---

## 2. mmap of model weights: can Metal/MLX consume file-backed pages directly?

### The zero-copy path exists, with an alignment contract
`MTLDevice.makeBuffer(bytesNoCopy:length:options:deallocator:)` "creates a buffer that wraps an existing contiguous memory allocation" and **allocates no new storage**. Requirements: the pointer must be **page-aligned**, the length must cover a page-aligned region, and the backing memory must come from `vm_allocate` or **`mmap`** (not `malloc`), within a single VM region. `[FROM-DOCS]` ([Apple makeBuffer(bytesNoCopy:)][nocopy])

**Implication:** you can `mmap` a weights file (e.g. a GGUF/safetensors blob on the external SSD), wrap the mapping in a zero-copy `shared` `MTLBuffer`, and have the **GPU read file-backed pages directly** — no explicit load step, no second copy in RAM. `[INFERRED]` This is how llama.cpp's mmap path makes weights "directly accessible to both the CPU and GPU." `[FROM-DOCS]` ([omr.it cold-start][omr])

### What happens on a page fault from the external SSD
On first access to a not-yet-resident page, the kernel's fault handler reads that page from the backing file into physical RAM, updates the page table, and resumes. `[FROM-DOCS]` ([omr.it cold-start][omr]) For *warm* reuse (multi-turn, repeated layers) this is a net win: a monolithic read becomes sub-ms faults amortized across passes. `[FROM-DOCS]` ([omr.it cold-start][omr])

**But for cold experts the fault is on the critical path and it is slow:**
- A GPU kernel that dereferences cold mmap'd pages stalls the command buffer until the SSD delivers them; if that exceeds the Metal watchdog, the command buffer is killed. Reported directly for MLX snapshots on NFS/external volumes vs internal SSD. `[FROM-DOCS]` ([MLX issue #3803][mlx3803])
- Page-fault reads are effectively **random, page-sized (16 KB)** I/O — the external SSD's *worst* access pattern, far below its sequential 2.5–3 GB/s. `[INFERRED]`

### Implications for cold-expert streaming
1. **Do not let the GPU fault on the external SSD directly.** `[INFERRED]` Prefer an explicit, CPU-driven staging read (`pread`/`madvise(MADV_WILLNEED)`/`mlock`) that brings the expert fully resident *before* a GPU kernel references it, so no command buffer ever waits on the SSD. `[INFERRED]` ([MLX issue #3803][mlx3803])
2. **Stream large, contiguous units.** Lay the file out so each expert's tensors are contiguous and page-aligned, and read whole experts (MB-sized sequential reads at ~2.5 GB/s) rather than faulting page-by-page. `[INFERRED]`
3. **mmap is still the right substrate** for the *resident* working set (shared layers, hot experts): it gives zero-copy CPU+GPU access and lets the OS reclaim cold pages under pressure. Just keep the SSD→RAM transition explicit and prefetched, not implicit via GPU faults. `[INFERRED]`

---

## 3. Memory pressure / swap on 32 GB macOS — staying safe

- **One pool, many tenants.** macOS, apps, and the model share the 32 GB; the model never gets all of it. `[FROM-DOCS]` ([insiderllm][insider])
- **GPU working-set cap.** `recommendedMaxWorkingSetSize` ≈ **75%** of unified RAM (~24 GB on 32 GB). The `iogpu.wired_limit_mb` sysctl raises the wired ceiling, but Apple's own guidance is to **leave 8–16 GB for macOS**; over-wiring starves the OS and can destabilize or hard-hang the machine. `[FROM-DOCS]`/`[INFERRED]` ([mehmetbaykar][baykar], [insiderllm][insider])
- **Compressed memory first, then swap.** macOS compresses inactive pages before swapping; an M1-class user reported ~19 GB of compressed memory under MLX load on a 32 GB-class machine — i.e. the compressor absorbs a lot before disk swap begins. `[FROM-DOCS]` ([sleepyquant / 19 GB compression][sleepy])
- **Swap onset is the cliff.** Once the resident set exceeds what compression can hide, macOS swaps to the **boot volume**; for LLM access patterns this collapses throughput (reports of 25 tok/s → ~2 tok/s), because weights are now served from disk, not RAM. Free disk space on the boot drive is effectively the memory system's "runway." `[FROM-DOCS]` ([insiderllm][insider], [llmconfigurator][llmconf])
- **Danger case:** a runaway local LLM filling the pool + swap has been reported to fill the boot volume and corrupt APFS. Guardrails must be in code, not operator discipline. `[FROM-DOCS]` ([hexisteme / APFS corruption][apfs])

**Safe envelope for `esh` on this box (practical):** `[INFERRED]`
- Keep the **resident GPU working set ≤ ~20–22 GB** (model weights + KV cache + activations), leaving ≥10 GB for macOS + the streaming/staging buffers.
- Treat the cold-expert cache as **purgeable/pageable**, sized so that `resident + cache` stays under the working-set ceiling and never forces compression into swap.
- **Watch the signal, not the vibe:** Memory Pressure must stay green; gate installs/inference on measured free RAM + free boot-disk space (this matches the existing `esh` resource-aware Auto routing + `resourcePressure`/`unload` APIs in the memory notes — extend them to MoE residency).
- Use MLX's own limits as the enforcement layer: `mx.set_memory_limit`, `mx.set_cache_limit`, `mx.set_wired_limit` (macOS 15+), `mx.clear_cache()`. `[FROM-DOCS]` ([MLX memory source][mlxmem])

---

## 4. CPU + GPU concurrency: when does it help vs hurt?

UMA makes "run cold experts on CPU while the GPU runs shared layers" *mechanically trivial* (same buffer, pick a stream). The question is whether it **pays**, and the answer is governed by the **shared 200 GB/s pool**. `[INFERRED]`

**It helps when the two engines are limited by *different* resources:** `[FROM-DOCS]`/`[INFERRED]`
- MLX's documented ~2× case pairs a **compute-bound GPU matmul** with an **overhead/latency-bound CPU op** — they don't fight for the same bottleneck. ([MLX unified-memory docs][mlx-um])
- For MoE: if the GPU is busy on a **compute-dense** phase (e.g. prefill/attention over a long context, which is arithmetic-intensive) while the CPU dequantizes/executes a **small** cold expert, the overlap is close to free. `[INFERRED]`

**It hurts when both engines are bandwidth-bound on the same pool:** `[INFERRED]`/`[THEORETICAL]`
- Decode is bandwidth-bound. If the GPU is already streaming shared-layer weights at near-200 GB/s, a concurrent CPU expert matmul reads from the **same** 200 GB/s pool and **steals bandwidth** — the two serialize on the memory controller even though they "run concurrently." Net throughput can drop, not rise. `[THEORETICAL]`
- The CPU's achievable memory bandwidth on M1 Pro is itself a fraction of the full 200 GB/s (the GPU can saturate more of it), so pushing large matmuls to the CPU is usually *slower per FLOP* and also contends. `[INFERRED]`

**Is UMA bandwidth the bottleneck? Yes — it is *the* bottleneck for this workload.** `[THEORETICAL]` 200 GB/s is generous vs a PCIe link but modest vs a discrete GPU's VRAM (~1 TB/s). Every design choice should minimize bytes-per-token crossing that pool.

**Design rule for `esh`:** `[INFERRED]`
- Use CPU execution for experts **only** to overlap with GPU phases that are *compute-bound* (prefill, attention) or *I/O-bound* (while another expert is being staged from SSD), **not** to parallelize two bandwidth-bound GEMMs.
- The more valuable CPU role is **I/O + staging + dequantization setup** (prefetch next experts from SSD, decompress into resident buffers) overlapped with GPU decode, rather than CPU *inference* of experts.

---

## 5. MLX vs llama.cpp (Metal): which exposes the control `esh` needs?

| Capability needed | MLX / mlx-lm | llama.cpp (Metal) |
|---|---|---|
| Zero-copy unified-memory arrays, explicit CPU/GPU op placement | **Yes, first-class** — arrays in unified memory, `stream=mx.cpu/gpu` per op, auto cross-stream deps `[FROM-DOCS]` ([mlx-um][mlx-um]) | Unified memory used implicitly; mmap makes weights CPU+GPU accessible, but **no per-op device-placement API** `[FROM-DOCS]` ([omr][omr]) |
| Custom tensor placement / partial offload | Arbitrary Python graph; you choose per-tensor device and can author custom Metal kernels `[FROM-DOCS]` | **`--n-cpu-moe N`** (keep MoE tensors of first N layers on CPU) and **`-ot/--override-tensor`** (regex tensor→buffer-type, e.g. keep `*_exps*` on CPU, rest on GPU with `-ngl 99`) — purpose-built MoE offload knobs `[FROM-DOCS]` ([llama-cli README][llcli], [someoddcodeguy MoE offload][sodc]) |
| mmap of weights | Loads safetensors; relies on OS caching. Memory governed by `set_memory_limit`/`set_cache_limit`/`set_wired_limit` `[FROM-DOCS]` ([mlxmem][mlxmem]) | **mmap by default** (`--no-mmap`/`--mlock` to control); mature streaming of >RAM models from disk `[FROM-DOCS]` ([omr][omr]) |
| KV-cache quantization & placement | mlx-lm supports KV-cache management + quantized KV; rotating/quantized caches in the library `[FROM-DOCS]` | **`--cache-type-k/-v`** (f16, q8_0, q4_0…); mixed K/V bit-widths researched (K8V4) `[FROM-DOCS]` ([hannecke tuning][hann], [KVSplit][kvsplit]) |
| Flash Attention | Fused attention kernels (incl. quantized-KV paths) in MLX `[FROM-DOCS]` | **`-fa`**; on Metal, **quantized V cache *requires* Flash Attention**; recent Metal backend dequantizes q8_0 KV→f16 pre-FA `[FROM-DOCS]` ([llama.cpp #21450][ll21450], [hannecke][hann]) |
| Speculative decoding / MTP | mlx-lm has speculative decoding (draft model) `[FROM-DOCS]` | Speculative decoding supported (`--model-draft`) `[FROM-DOCS]` |
| MoE-larger-than-RAM expert streaming | Possible to build (unified arrays + custom graph), but **you implement the streaming/caching yourself**; no turnkey disk-expert streamer `[INFERRED]` | mmap lets a >RAM MoE run by faulting experts from disk, but you don't control *which* engine faults or when (watchdog risk on slow disks) `[INFERRED]` ([mlx3803][mlx3803]) |

### Current limitations on Apple Silicon
- **MLX:** No built-in SSD expert-streaming/eviction policy — `esh` must author the resident/cache/stream tiers and the Metal/Accelerate expert kernels itself. Aggressive caching holds memory until `clear_cache()`. macOS 15+ required for `set_wired_limit`. `[FROM-DOCS]`/`[INFERRED]` ([mlxmem][mlxmem], [mlx issue #2668][mlx2668])
- **llama.cpp:** MoE offload knobs (`--n-cpu-moe`, `-ot`) are coarse (layer/regex granularity, not per-token hot-set), the CPU side runs experts on CPU (bandwidth contention, §4), and letting the GPU fault directly on an external SSD risks the Metal watchdog. Quantized-V KV requires FA and has had Metal-specific gaps. `[FROM-DOCS]`/`[INFERRED]` ([ll21450][ll21450], [mlx3803][mlx3803])

**Verdict for `esh`:** **MLX is the better substrate for the architecture UMA favors**, because the differentiator here is *fine-grained, per-token control of tensor placement and custom streaming/caching* over a single unified pool — which MLX exposes directly (unified arrays + per-op streams + custom Metal kernels + memory-limit APIs). llama.cpp is the better **reference/validation baseline** and ships the most mature turnkey MoE-offload flags, but its control surface is coarser than what SSD-backed per-token expert streaming wants. `[INFERRED]`

---

## 6. KV-cache placement & quantization on UMA

- On UMA there is **no separate VRAM for the KV cache** — it lives in the same pool and competes byte-for-byte with weights and activations, and it's read every decode step (so it's *bandwidth* cost, not just capacity). `[INFERRED]`
- **Quantize it.** q8_0 keys roughly halve KV footprint and traffic vs f16 with minimal loss; q4 is more aggressive. Keys are more sensitive than values → **asymmetric K8V4** (8-bit K, 4-bit V) gives large memory cuts (~59% reported) at ~0.9% perplexity cost. `[FROM-DOCS]` ([KVSplit][kvsplit], [hannecke][hann])
- **Flash Attention is effectively a prerequisite** for quantized KV on Metal (quantized V requires FA; q8_0 KV is dequantized to f16 pre-FA in recent builds). Enable FA whenever quantizing the cache. `[FROM-DOCS]` ([llama.cpp #21450][ll21450])
- **Placement:** keep the KV cache in a resident `shared`/wired region (it's touched every token on the GPU — never let it be purgeable/faultable). Budget it explicitly against the §3 working-set ceiling; at long context it can rival weights in size. `[INFERRED]`
- MLX exposes KV-cache management (incl. quantized/rotating caches) in mlx-lm, so KV placement/quant is controllable in the same framework as expert placement. `[FROM-DOCS]`

---

## 7. Recommendation: what architecture does UMA favor for a 100B+ MoE (~few B active/token) on M1 Pro 32 GB?

**Headline:** UMA turns the problem from "copy experts across a bus" into "**tier one memory pool and schedule around a 200 GB/s bandwidth wall + a slow SSD**." The optimal shape is a **3-tier resident/cache/stream design with a single zero-copy weight representation and explicit (not fault-driven) SSD staging.** `[INFERRED]`

### Model sizing first
A 100B+ MoE at **4-bit** ≈ ~50–60 GB on disk — does not fit in 32 GB, so streaming is mandatory. With ~3–4B active params/token at 4-bit, the *active* weight traffic is only ~1.5–2 GB/token ⇒ a RAM-resident active set has a ~10 ms/token (~100 tok/s) bandwidth floor. The entire game is making "active this token" ≈ "already resident." `[THEORETICAL]`

### The 3 tiers (all one `shared`/unified pool, no copies between CPU and GPU)
1. **Wired / always-resident (~target ≤ ~14–16 GB):** embeddings, all attention + router/gate weights, LayerNorms, and the **KV cache** (quantized, §6). These are touched every token → must never fault. Store as 4-bit, zero-copy `shared` buffers; GPU executes. `[INFERRED]`
2. **Hot-expert LRU cache in unified memory (~4–6 GB, purgeable):** the experts actually being hit for the current workload. MoE expert reuse is skewed, so a modest cache captures most hits; executed on GPU with no copy. Size it so Tier1+Tier2 stay under the §3 ceiling. `[INFERRED]`/`[THEORETICAL]`
3. **Cold experts on external SSD (the other ~35–45 GB):** mmap'd, page-aligned, **one contiguous block per expert** for large sequential reads, pulled in on miss. `[INFERRED]`

### The scheduling loop (why UMA makes this work)
- **Router-ahead prefetch:** the gate/router selects experts *before* the FFN runs. Use that lead time to issue an **explicit CPU-driven staging read** (`pread`/`madvise(WILLNEED)`) of missing experts into resident buffers, overlapped with the GPU finishing attention — so the **GPU never faults on the SSD** (avoids the Metal watchdog, §2). `[INFERRED]` ([mlx3803][mlx3803])
- **Zero-copy handoff:** once staged, the expert is already in a `shared` buffer — the GPU kernel reads it with no further copy. This is the UMA payoff: staging cost is "SSD→RAM once," not "SSD→RAM→VRAM." `[FROM-DOCS]`/`[INFERRED]` ([nocopy][nocopy])
- **CPU/GPU overlap, used correctly (§4):** use the CPU for **I/O + dequant/staging** of upcoming experts (overlaps a GPU phase), and optionally to execute a *cold* expert that missed the cache **only while the GPU is in a compute-bound phase**; do **not** run CPU expert GEMMs concurrently with GPU decode GEMMs (bandwidth contention on the shared pool). `[INFERRED]`/`[THEORETICAL]`
- **Quantize everything on the wire and in RAM** (4-bit weights, q8/q4 KV) to shrink both the resident footprint *and* the per-token bandwidth — the directly actionable lever against the 200 GB/s wall. `[INFERRED]`

### Framework & guardrails
- **Build on MLX** (unified arrays, per-op `stream` placement, custom Metal/Accelerate expert kernels, `set_memory_limit`/`set_wired_limit`/`clear_cache`), authoring the streaming/eviction layer `esh` needs; keep **llama.cpp (`--n-cpu-moe`/`-ot`, `-fa`, `--cache-type-*`) as the validation baseline**. `[FROM-DOCS]`/`[INFERRED]`
- **Hard guardrails in code** (§3): cap wired memory leaving ≥10 GB for macOS, keep Memory Pressure green, gate on free RAM *and* free boot-disk space, and never allow the resident set to push into swap (APFS-corruption risk). Reuse the existing `esh` resource-aware Auto routing + `resourcePressure`/`unload` machinery. `[INFERRED]`

### Honest expectation
Best case (high cache-hit rate, experts prefetched, quantized) approaches the ~RAM-bandwidth floor for the active set (tens of tok/s). Worst case (cold, low reuse, external-SSD random I/O) is dominated by ~2.5 GB/s streaming and will be **single-digit tok/s or worse** — so the architecture's value is entirely in **maximizing resident reuse and hiding SSD latency behind compute**, which is precisely what UMA (one pool, zero-copy, per-op placement) makes achievable where a discrete-GPU design could not. `[THEORETICAL]`

---

## Design implications (summary)

1. **UMA removes the host↔device copy** → one zero-copy weight representation (`shared`/unified), CPU-vs-GPU execution becomes a *scheduling* choice, not a data-movement one. `[FROM-DOCS]` ([apple-shared][apple-shared], [mlx-um][mlx-um])
2. **The 200 GB/s pool is the bottleneck**, and it's *shared*. Minimize bytes/token; don't run two bandwidth-bound GEMMs on CPU+GPU at once. `[THEORETICAL]`
3. **Never let the GPU page-fault on the external SSD** — explicit, router-ahead, CPU-driven staging into resident `shared` buffers; stream large contiguous per-expert blocks. `[FROM-DOCS]`/`[INFERRED]` ([mlx3803][mlx3803], [nocopy][nocopy])
4. **Tier memory: wired always-on + purgeable hot-expert LRU + SSD cold tier.** Keep wired set ≤ ~20–22 GB; KV cache is wired and quantized. `[INFERRED]`
5. **Quantize weights (4-bit) and KV (q8/q4, asymmetric K8V4 + Flash Attention)** to cut both footprint and per-token traffic. `[FROM-DOCS]` ([kvsplit][kvsplit], [ll21450][ll21450])
6. **MLX is the control substrate; llama.cpp is the baseline.** MLX gives per-op placement + custom kernels + memory APIs; llama.cpp gives mature but coarse MoE-offload flags. `[FROM-DOCS]`/`[INFERRED]`
7. **Guardrails in code** against swap/APFS corruption; integrate with existing `esh` resource-pressure/unload APIs. `[INFERRED]`

---

## Sources

- Apple, *Choosing a resource storage mode for Apple GPUs* (shared/private/memoryless; unified memory): https://developer.apple.com/documentation/metal/choosing-a-resource-storage-mode-for-apple-gpus
- Apple, *Choosing a resource storage mode for Intel and AMD GPUs* (contrast / discrete-memory model): https://developer.apple.com/documentation/metal/choosing-a-resource-storage-mode-for-intel-and-amd-gpus
- Apple, *MTLStorageMode*: https://developer.apple.com/documentation/metal/mtlstoragemode
- Apple, *MTLDevice.makeBuffer(bytesNoCopy:length:options:deallocator:)* (page-aligned mmap/vm_allocate zero-copy): https://developer.apple.com/documentation/metal/mtldevice/makebuffer(bytesnocopy:length:options:deallocator:)
- Apple Developer Forums, *Metal makeBuffer* (page-alignment/mmap requirement): https://developer.apple.com/forums/thread/725994
- MLX docs, *Unified Memory* (arrays in unified memory, `stream=mx.cpu/gpu`, auto deps, ~2× concurrency): https://ml-explore.github.io/mlx/build/html/usage/unified_memory.html
- MLX memory management source (`set_memory_limit`, `set_cache_limit`, `set_wired_limit`, `clear_cache`): https://huggingface.co/Fahad-S/FastVLM_SANA/blob/main/ml-stable-diffusion/mlx/python/src/memory.cpp
- MLX issue #3803 (Metal watchdog timeout loading models from NFS/external volumes vs internal SSD): https://github.com/ml-explore/mlx/issues/3803
- MLX issue #2668 (MLX cache holds memory until cleared): https://github.com/ml-explore/mlx/issues/2668
- llama.cpp CLI README (`--n-cpu-moe`, `--override-tensor`/`-ot`, `-ngl`, `--cache-type-k/-v`, `-fa`, mmap flags): https://dyn.manpages.debian.org/unstable/llama.cpp-tools/llama-cli.1.en.html
- llama.cpp issue #21450 (Metal quantized KV / Flash-Attention requirement and dequant pre-FA): https://github.com/ggml-org/llama.cpp/issues/21450
- someoddcodeguy, *Understanding MoE Offloading* (`-ngl 99` + `--n-cpu-moe`, `-ot` for expert offload): https://dev.to/someoddcodeguy/understanding-moe-offloading-5co6
- Michael Hannecke, *Tuning llama.cpp on Apple Silicon* (KV cache types, FA): https://medium.com/@michael.hannecke/tuning-llama-cpp-on-apple-silicon-843f37a6c3dc
- KVSplit (asymmetric K8V4 KV quantization on Apple Silicon): https://hn.svelte.dev/item/44009321
- omr.it, *The Cold Start Problem in Mobile LLMs* (mmap, page-fault-on-demand, CPU+GPU file-backed access): https://omr.it.com/blog/memory-mapped-model-weights-ios-llm-loading/
- insiderllm, *Ollama on Mac: Metal, Memory Pressure, Slow Performance* (shared pool, working-set cap, swap collapse): https://insiderllm.com/guides/ollama-mac-troubleshooting/
- mehmetbaykar, *Increase VRAM on Apple Silicon* (`recommendedMaxWorkingSetSize` ~75%, `iogpu.wired_limit_mb`): https://mehmetbaykar.com/posts/increase-vram-apple-silicon-local-llm/
- sleepyquant (DEV), *What 19 GB of memory compression taught me about MLX on M1 Max* (compressed memory): https://dev.to/sleepyquant/what-19-gb-of-memory-compression-taught-me-about-mlx-on-m1-max-3eha
- hexisteme (DEV), *How a runaway local LLM corrupted APFS* (swap/disk-fill risk): https://dev.to/hexisteme/the-guardrail-has-to-be-code-how-a-runaway-local-llm-corrupted-apfs-and-bricked-a-mac-mini-4780
- llmconfigurator, *Mac swapping instead of running*: https://llmconfigurator.com/en/guides/troubleshooting/mac-swapping-instead-of-running
- sitepoint, *Local LLMs on Apple Silicon (2026)* (bandwidth-bound decode): https://www.sitepoint.com/local-llms-apple-silicon-mac-2026/
- starmorph, *Apple Silicon LLM inference optimization guide* (tok/s ≈ bandwidth ÷ bytes/token): https://blog.starmorph.com/blog/apple-silicon-llm-inference-optimization-guide

[apple-shared]: https://developer.apple.com/documentation/metal/choosing-a-resource-storage-mode-for-apple-gpus
[amd]: https://developer.apple.com/documentation/metal/choosing-a-resource-storage-mode-for-intel-and-amd-gpus
[nocopy]: https://developer.apple.com/documentation/metal/mtldevice/makebuffer(bytesnocopy:length:options:deallocator:)
[mlx-um]: https://ml-explore.github.io/mlx/build/html/usage/unified_memory.html
[mlxmem]: https://huggingface.co/Fahad-S/FastVLM_SANA/blob/main/ml-stable-diffusion/mlx/python/src/memory.cpp
[mlx3803]: https://github.com/ml-explore/mlx/issues/3803
[mlx2668]: https://github.com/ml-explore/mlx/issues/2668
[llcli]: https://dyn.manpages.debian.org/unstable/llama.cpp-tools/llama-cli.1.en.html
[ll21450]: https://github.com/ggml-org/llama.cpp/issues/21450
[sodc]: https://dev.to/someoddcodeguy/understanding-moe-offloading-5co6
[hann]: https://medium.com/@michael.hannecke/tuning-llama-cpp-on-apple-silicon-843f37a6c3dc
[kvsplit]: https://hn.svelte.dev/item/44009321
[omr]: https://omr.it.com/blog/memory-mapped-model-weights-ios-llm-loading/
[insider]: https://insiderllm.com/guides/ollama-mac-troubleshooting/
[baykar]: https://mehmetbaykar.com/posts/increase-vram-apple-silicon-local-llm/
[sleepy]: https://dev.to/sleepyquant/what-19-gb-of-memory-compression-taught-me-about-mlx-on-m1-max-3eha
[apfs]: https://dev.to/hexisteme/the-guardrail-has-to-be-code-how-a-runaway-local-llm-corrupted-apfs-and-bricked-a-mac-mini-4780
[llmconf]: https://llmconfigurator.com/en/guides/troubleshooting/mac-swapping-instead-of-running
[sp]: https://www.sitepoint.com/local-llms-apple-silicon-mac-2026/
[star]: https://blog.starmorph.com/blog/apple-silicon-llm-inference-optimization-guide
