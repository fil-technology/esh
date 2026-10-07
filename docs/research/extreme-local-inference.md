# esh — Extreme Local Inference: Phase A + B findings

**Target machine:** Apple M1 Pro · 32 GB unified memory · external ~2 TB exFAT/USB SSD · macOS 26.
**Date:** 2026-10-07. **Status:** Phase A (landscape) + Phase B (hardware benchmark) complete. No full model
has been run yet — see "What is and isn't proven".

## Evidence labels (mandatory, per brief §33)

- **MEASURED** — a number this project measured on the target machine.
- **THEORETICAL** — a projection/napkin estimate; not yet run here.
- **FROM-SOURCE** — taken from a primary source (repo/docs) we read directly.
- **FROM-AGENT** — produced by a Phase-A research subagent; useful but secondary, may contain errors.
- **REPRODUCED / VALIDATED** — reserved for later phases; nothing qualifies yet.

## What is and isn't proven

- **Proven (MEASURED):** this machine's compute, memory bandwidth, external-SSD cold read behavior
  (`benchmarks/hardware-profile.json`), AND the first model run — **Qwen3-30B-A3B-4bit at 28.7 tok/s, 17.3 GB,
  swap-safe** (REPRODUCED; `benchmarks/model-results.json`).
- **NOT yet proven:** the 80B-resident bet (deferred for safety — see Phase C below) and all other model tok/s,
  which remain **THEORETICAL** until run. Do not read an unlabelled model number as success.

## Phase C — first MEASURED model runs (2026-10-07)

- **Qwen3-30B-A3B-4bit (MLX) — MEASURED / REPRODUCED:** generation **28.7 tok/s**, peak **17.3 GB**, swap-safe;
  cold TTFT 5.7 s and prompt 6.9 tok/s include first-run Metal kernel compilation. Confirms the thesis: a
  3B-active 30B MoE is comfortably *interactive* (≥10 tok/s) on this machine, fully resident. ✅
- **Qwen3-Next-80B-A3B IQ2_XS (22.2 GB, llama.cpp b8660 Metal) — DEFERRED (safety, §29):** download reached
  ~12 GB on the SSD (resumable) but the run was **killed before load**. Reason = the **binding memory-safety
  finding below**. Metal reported `recommendedMaxWorkingSetSize = 26.8 GB` (~84% of RAM), so the model itself
  would fit the GPU working set; the blocker is system-level swap/disk, not Metal.

### MEASURED memory-safety ceiling (the real limit on this machine)

The resident-model ceiling here is set by **internal-disk/swap headroom, not the 32 GB of RAM**. The boot APFS
container is chronically ~full (user Data volume = **413 GB of 460 GB**), leaving **~310 MB free**, and swap was
**~94% used (8.19/8.70 GB)**. A ~17 GB model is safe; a ~22 GB model is unsafe until space is freed or a reboot
reclaims swap (~8 GB → container ~9–10 GB free). **This is the binding constraint for the >RAM / resident-80B
strategy on this exact setup** — and a concrete instance of the brief's §29 stop condition. Retry path: reboot,
then resume the IQ2_XS download and run with live memory monitoring + hard abort.

## Provenance / corrections (important)

Four research subagents produced the companion docs (`strata-analysis.md`, `apple-unified-memory-inference.md`,
`model-landscape.md`, `runtime-landscape.md`). They are **FROM-AGENT drafts**. Known issues, reconciled here:

- Web search returned **fabricated items** (impossible arXiv years like 2601/2607; invented model names). Agents
  mostly excluded these; treat any arXiv id or exotic name in the drafts as unverified unless marked FROM-SOURCE.
- `model-landscape.md` claims **"no public system named Strata"** and that **"Qwen3.8-Flash-Next isn't a real
  model."** Both are **WRONG** — I verified the primary source directly (FROM-SOURCE): `github.com/mach10x/strata`
  (MIT) exists and its README states it runs **"Qwen3.8-Flash-Next … a team of 24,576 small specialists, and each
  word needs only 10 of them."** Strata calls it a **125B** MoE. Where the drafts conflict with this, this
  document wins.
- Strata's performance figures are the **authors' own**, mostly on one RTX 5070 box, often in-sample/extrapolated
  (FROM-AGENT caveat). Treat as THEORETICAL for our purposes.

## Phase B — MEASURED hardware ceilings

| Metric | MEASURED | Why it matters |
|---|---|---|
| Unified memory | 32 GB (16 KB pages) | hard capacity wall |
| Internal free (swap volume) | **9.6 GB** | tiny swap headroom → swap = danger, not a safety net |
| GPU matmul fp16 (MLX) | ~3.7 TFLOP/s | prompt-processing / prefill compute |
| GPU elementwise bandwidth | ~79 GB/s (floor; spec ~200) | decode is bandwidth-bound |
| **Resident 4-bit weight read (decode)** | **~39 GB/s effective** | the "fits in RAM" ceiling |
| **External SSD sequential read (cold)** | **~1.0 GB/s** | the "stream from SSD" ceiling |
| **External SSD random read (cold, ≥1 MiB)** | **~0.9–1.1 GB/s** | MoE experts are MB-scale random reads |
| External SSD random read (64 KiB) | ~0.31 GB/s, 0.25 ms p50 | small reads (e.g. PLE table) are far worse |
| External SSD random read latency | 1 MiB ≈ 1.5 ms · 16 MiB ≈ 19 ms · 64 MiB ≈ 76 ms (p50) | per-token stalls stack |

Cache caveat: a naive test reported 10–80 GB/s (page cache). Defeated with a >RAM (40 GiB) file; cold numbers
agree with the fsync'd write (0.87 GB/s). Method in `benchmarks/README.md`.

### The governing inequality

```
resident 4-bit weight read   ≈ 39 GB/s
external SSD cold read        ≈  1 GB/s        → resident is ~40× faster
SSD-streamed model tok/s ≈ 1.0e9 / (bytes read from SSD per token)
```

**Conclusion (THEORETICAL, from MEASURED ceilings): on THIS machine, the winning lever is fitting the model in
RAM via mixed quantization, NOT streaming experts off the external SSD.** Streaming a 125B/≈63 GB model (Strata's
own target footprint) at 1 GB/s with ~0.66 GB of experts/token lands around **~1.5 tok/s cold** — at or below the
brief's 2 tok/s stop condition — before counting the 28.8 GB SSD-only lookup table's many small random reads,
which the 64 KiB number (0.31 GB/s) says are the real tax. A Thunderbolt/NVMe SSD (~3 GB/s) would roughly triple
these; the current exFAT/USB enclosure is a key limiter.

## Strata — architecture & Apple verdict (see strata-analysis.md)

- Real, MIT, C++17/**CUDA** (ROCm via a HIP shim); **no cheap Metal port**. FROM-SOURCE + FROM-AGENT.
- Tiering: dense + routers + shared experts + head + MTP (~5.4 GiB) pinned in VRAM; ~34 GB routed experts split
  VRAM-cache ∪ pinned-RAM ∪ SSD; a ~28.8 GB per-layer-embedding (PLE) table is SSD-only. Hotness = offline
  frequency profile + decayed online counts; hot→GPU, cold→CPU (AVX-512) in place; router-lookahead prefetch.
- **Verdict: do NOT port. Build Mac-native (MLX/Metal).** Most of Strata's machinery (pinned arenas, PCIe-split,
  separate VRAM copies) exists to fight the PCIe divide that **Apple unified memory removes**. The portable ideas:
  RAM↔SSD tiering, an offline+online expert-frequency profile, adaptive residency, router-lookahead prefetch,
  direct small-block I/O for the lookup table, and the speculative-decode stack.

## Apple unified memory (see apple-unified-memory-inference.md)

One pool, zero host↔device copies: CPU-vs-GPU expert execution is a scheduling choice, not a data move. MLX
exposes this directly (unified arrays, per-op `stream=cpu/gpu`, `set_memory_limit`/`set_wired_limit`). The shared
~200 GB/s pool is the real bottleneck (decode is bandwidth-bound), so CPU+GPU concurrency helps only across
different bottlenecks and hurts when two bandwidth-bound GEMMs contend. Never let the GPU page-fault on the
external SSD (command-buffer stall / watchdog) — stage experts explicitly. Keep wired set ≤ ~20–22 GB.

## Model shortlist (THEORETICAL tok/s from measured ceilings; see model-landscape.md)

| Rank | Model | Total / active | Fit on 32 GB | Projected tok/s | Note |
|---|---|---|---|---|---|
| 1 | **Qwen3-Next-80B-A3B** | 80B / **3B** | **IQ2 ≈ 23 GB fully resident** | strong, no streaming | 80B-class brain, 3B active; the bet |
| 2 | Qwen3-30B-A3B | 30B / 3.3B | Q4 ≈ 17 GB resident | ~18–30 | safe fast baseline |
| 3 | gpt-oss-20b | 21B / 3.6B | MXFP4 ≈ 12 GB | ~15–25 | native 4-bit, trivial fit |
| 4 | GLM-4.5-Air | 106B / 12B | IQ2 ≈ 26–28 GB (marginal) | ~4–7 | strongest coder that nearly fits |
| 5 | Granite-4.0-H-Small | 32B / 9B | Q4 ≈ 17 GB | ~8–14 | hybrid Mamba2, cheap long ctx |
| 6 | gpt-oss-120b | 117B / 5.1B | ~63 GB → SSD-streamed | ~1–2 | the >>RAM stress test |

The thesis holds: decode cost tracks **active params × expert granularity × a tiny resident core**, not total
size. Fine-grained MoE (Qwen3-Next, gpt-oss, Qwen3-30B) dominates the giants on this machine.

## Preliminary answers to the brief's §30 questions

Answerable now from Phase A/B (others deferred to Phase C/D, labelled pending):

- Largest *useful* dense: ~32B (Q4), practical ceiling; 70B dense = ~2–4 tok/s curiosity; 100B+ dense = out. THEORETICAL.
- Strongest model at ≥10 tok/s: a 3B-active MoE (Qwen3-30B-A3B / gpt-oss-20b). THEORETICAL.
- Strongest at ≥2 tok/s: likely Qwen3-Next-80B (resident IQ2) or GLM-4.5-Air (marginal). PENDING Phase C.
- How much does SSD speed matter / observed pattern: decisive, and the pattern is MB-scale random reads capped at
  **~1 GB/s** (MEASURED); it makes pure streaming of >RAM giants sub-2 tok/s here.
- Does unified memory help: yes — removes copies and the need for most of Strata's plumbing (FROM-SOURCE/INFERRED).
- Best runtime today: **llama.cpp (Metal)** baseline + **MLX** quant/iteration lab. Custom Metal work NOT justified
  yet; a bounded resident-expert cache on MLX is the only candidate, and only if Phase C shows fit-to-RAM isn't enough.
- What should `esh run --best` choose *today*: **PENDING** — provisionally Qwen3-30B-A3B (Q4) for interactive and
  Qwen3-Next-80B-A3B (IQ2) for best quality, to be set by Phase-C measurement.

## BEST CURRENT CONFIGURATION (THEORETICAL — not yet run)

```
Model:            Qwen3-Next-80B-A3B        (confirm vs Strata's "Qwen3.8-Flash-Next" 125B variant)
Total / active:   80B / ~3B per token
Runtime:          MLX (mlx-lm)  [llama.cpp Metal as cross-check]
Quantization:     IQ2 / mixed (2-bit experts, higher-precision attention+router+shared+embeddings)
RAM:              ~23 GB resident  (leaves ~9 GB for macOS + KV; under the ~22 GB wired guidance)
SSD:              none required at IQ2 (fits) — this is the point
Context:          target 16–32K with Q8/Q4 KV
Why this wins:    80B-class quality at 3B active, fully resident → avoids the ~1 GB/s SSD wall entirely
```

Label: **THEORETICAL.** Promote to MEASURED → REPRODUCED → VALIDATED only after Phase C runs it through esh's
guarded path and the quality suite (§15).

## EXTREME MODEL FRONTIER (THEORETICAL)

- **≥10 tok/s:** 3B-active MoE, resident (Qwen3-30B-A3B Q4, gpt-oss-20b).
- **≥5 tok/s:** Granite-4.0-H-Small (Q4); Qwen3-Next-80B if IQ2 resident decode hits target.
- **≥2 tok/s:** GLM-4.5-Air (IQ2, marginal fit); larger MoE only if resident.
- **Technically runnable (<2 tok/s):** gpt-oss-120b / Strata's 125B target via SSD streaming (~1–1.5 tok/s cold).
- **Not worth pursuing here:** 100B+ **dense**; and SSD-streaming any model whose per-token expert bytes × (1 GB/s)⁻¹
  exceed ~0.5 s — the external exFAT/USB SSD is the wall.

## Next (Phase C — get to MEASURED/VALIDATED)

1. Run **Qwen3-30B-A3B (MLX 4-bit)** end-to-end through esh's guarded runtime — real tok/s, TTFT, peak memory,
   30-min stability, quality smoke. First REPRODUCED data point.
2. Run **Qwen3-Next-80B-A3B at IQ2** resident — the headline bet; confirm it fits ≤ ~23 GB and stays swap-safe.
3. Resolve the **Qwen3.8-Flash-Next (125B) vs Qwen3-Next-80B** identity (which HF weights) before any streaming test.
4. Only if (1)/(2) disappoint: synthetic expert-streaming prototype (Phase E) — but the SSD ceiling predicts it
   won't beat fit-to-RAM here.
