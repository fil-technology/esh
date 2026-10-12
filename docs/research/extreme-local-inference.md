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
  (`benchmarks/hardware-profile.json`), AND two model runs — **Qwen3-30B-A3B-4bit (MLX) at 28.7 tok/s, 17.3 GB**
  and **Qwen3-Next-80B-A3B IQ2_XS (llama.cpp) at 21.1 tok/s, 21.2 GB** — both resident and swap-safe
  (`benchmarks/model-results.json`). The headline bet (80B-class, resident, interactive on 32 GB) is confirmed
  on speed + safety.
- **Utility — MEASURED (objective suite, `benchmarks/quality/`):** both models score **9/9** on executable-code,
  reasoning, structured-output, tool-call, instruction, and needle tasks. The suite does **not** discriminate
  quality; the measured difference is **speed (30B ~2–3× faster) + safety (no reboot needed)**. The earlier
  "80B subtly buggy" was a single non-representative sample (the objective Python debounce passed). Where IQ2
  hurts / where 80B capacity helps is not yet shown — needs a harder task set. Other models' tok/s remain THEORETICAL.

## Phase C — first MEASURED model runs (2026-10-07)

- **Qwen3-30B-A3B-4bit (MLX) — MEASURED / REPRODUCED:** generation **28.7 tok/s**, peak **17.3 GB**, swap-safe;
  cold TTFT 5.7 s and prompt 6.9 tok/s include first-run Metal kernel compilation. Confirms the thesis: a
  3B-active 30B MoE is comfortably *interactive* (≥10 tok/s) on this machine, fully resident. ✅
- **Qwen3-Next-80B-A3B IQ2_XS (22.2 GB, llama.cpp b8660 Metal) — MEASURED / VALIDATED (speed+safety):**
  generation **21.1 tok/s**, prompt 25.8 tok/s; **21.2 GB resident on Metal** (25.6 of 26.8 GB, 3.7 GB headroom);
  **swap-safe** (free RAM bottomed 1.7 GB, swap peaked 2.6 GB, 0 swaps, watchdog never fired). **An 80B-class
  model runs resident and INTERACTIVE on a 32 GB M1 Pro.** Required a reboot first (see safety finding); unsafe
  before it. Runtime note: this needs llama.cpp because the fit depends on the **GGUF IQ2 (~2-bit) quant** — the
  lowest MLX quant is 4-bit (~40 GB, doesn't fit). **Quality caveat:** IQ2 is lossy — the sample Swift debounce
  was fluent but subtly wrong (never cancels the prior task), so this 80B is NOT automatically better than the
  clean 4-bit 30B for correctness-sensitive work. `--best` needs the §15 quality suite to settle. First MLX-vs-
  llama.cpp, 30B-vs-80B utility datapoint.

### MEASURED memory-safety ceiling (the real limit on this machine)

The resident-model ceiling here is set by **internal-disk/swap headroom, not the 32 GB of RAM**. The boot APFS
container is chronically ~full (user Data volume = **413 GB of 460 GB**). **Confirmed both ways:** the 22 GB
80B IQ2_XS was **unsafe** when swap was ~94% used (310 MB container free) — killed before load (§29) — but
**safe after a reboot** reclaimed ~8.2 GB of swap (ran at 21 tok/s, swap peaked 2.6 GB, 0 swaps). Practical
`--best` fit-gating rule for this box: a resident model is safe to **~22–23 GB only with a fresh swap/disk
state** (post-reboot or ≥10 GB internal free); otherwise cap **~17 GB**. Metal
`recommendedMaxWorkingSetSize = 26.8 GB` is the hard upper bound regardless.

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

## BEST CURRENT CONFIGURATION (MEASURED on speed+safety; utility pending §15)

Two viable configs, pick by task until the quality suite decides:

```
INTERACTIVE / correctness-sensitive (today's safe default):
  Model:        Qwen3-30B-A3B        Runtime: MLX 4-bit
  Speed:        28.7 tok/s           Resident: 17.3 GB (swap-safe any time)
  Why:          fast, clean 4-bit, fits with margin; fewer quant artifacts than IQ2

MAX-BRAIN resident (when quality/size matters more than a bug-free first draft):
  Model:        Qwen3-Next-80B-A3B   Runtime: llama.cpp IQ2_XS (GGUF ~2-bit)
  Speed:        21.1 tok/s           Resident: 21.2 GB (swap-safe ONLY post-reboot / >=10 GB internal free)
  Caveat:       IQ2 is lossy — sample code was fluent but subtly wrong; verify outputs
```

Label: **MEASURED** (speed + memory-safety + a 9/9 objective quality suite each). **Decision: default to the
30B.** On measured utility — equal objective quality, ~2–3× faster, swap-safe anytime — the smaller model is the
better default; the 80B is an opt-in `--max-quality` tier, not a silent default (IQ2 lossy; needs reboot
headroom). Identity question (Qwen3-Next-80B vs Strata's "Qwen3.8-Flash-Next" 125B) is moot for `--best`: the
public 80B at IQ2_XS is the one that runs. Full comparison: `benchmarks/quality/README.md`.

## Quantization frontier for the resident 80B (Priority 2) — sizes FROM-SOURCE, ceilings MEASURED

Can a higher-quality 80B quant fit safely? Evaluated against the two measured ceilings — Metal
`recommendedMaxWorkingSetSize = 26.8 GB` (hard) and the swap-safe resident band **~22–23 GB** (post-reboot) —
BEFORE downloading anything:

| Quant | Size | Verdict on 32 GB M1 Pro |
|---|---|---|
| IQ2_XXS | 19.3 GB | safe; lower quality than XS |
| **IQ2_XS** | **22.2 GB** | **tested — safe post-reboot, 9/9 quality** |
| IQ2_S | 23.4 GB | ~1.2 GB above XS; likely safe post-reboot, only marginal headroom for KV — the *only* upgrade worth a single guarded experiment |
| IQ2_M | 26.1 GB | at the 26.8 GB Metal cap → ~0.7 GB left for KV+compute → will OOM/swap. **Reject (no download).** |
| Q2_K / Q2_K_L | 28.2 / 28.5 GB | exceed the 26.8 GB Metal working set → won't load on GPU. **Reject.** |
| IQ3_* | ≥ ~27 GB | exceed the Metal ceiling. **Reject.** |

**Conclusion:** the practical quality headroom above IQ2_XS is **only IQ2_S (23.4 GB)**; everything IQ3+ overruns
the Metal/safety ceiling on 32 GB. Since IQ2_XS already scores 9/9 on the objective suite, there is **no measured
evidence it is quality-limited**, so downloading IQ2_S now isn't justified (respects "evaluate sizes before
downloading" + "one large experiment at a time"). Hold IQ2_S as a single guarded experiment *iff* a harder,
discriminating task set later shows IQ2_XS failing where the 30B or a bigger quant would not.

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
