# esh — Best Local Coding Intelligence (Research Report)

**Date:** 2026-10-14 · **Scope:** strongest practical open-weight *coding* models + inference configs for esh on Apple Silicon · **Status:** RESEARCH ONLY — no weights downloaded, no models touched, SSD read-only, nothing merged/implemented.

**Target hardware:** MacBook Pro, Apple M1 Pro, 32 GB unified memory, model storage on external SSD (measured ~1.0 GB/s sequential read, exFAT/USB).

**esh state audited:** working tree `migration/mlx-swift-0.31` (VERSION `2.4.0-rc.35`, HEAD `f358678`); authoritative `origin/main = e40d4ad` (rc.36 line). mlx-swift pinned `0.32.3`, mlx-swift-lm `3.32.3`. Python text bridge requires `mlx_lm>=0.31.3`, `mlx-vlm==0.5.0`.

### Evidence tiers (used throughout)
- **[VERIFIED]** — from primary source (official model card/repo, or esh source `file:line`, or a measurement recorded in this repo).
- **[PUBLISHED-BENCHMARK]** — a number self-reported on an official model card / vendor report. *Vendor-reported, not independently reproduced.* Several of the 2026 coder-model card numbers could not be cross-checked and some SEO/vendor pages during research were found to contain fabricated scores — treat all card numbers as **claims to verify**, not ground truth.
- **[ESTIMATE]** — engineering inference (fit/speed math), clearly not measured.
- **[HYPOTHESIS]** — requires measurement to confirm.

---

## 0. Executive summary

- esh already runs the **right shape** of model for 32 GB: a **3B-active MoE at 4-bit** (`Qwen3-30B-A3B-4bit`, installed, **[VERIFIED]** 28.65 lab tok/s / ~37 tok/s interactive, 17.3 GB peak). The research question is really "what is a *better coder* that keeps that shape and fit?"
- **The landscape moved since Jan 2026.** The strongest *fitting* upgrades are all **~30B-class, 3B-active MoE**: **GLM-4.7-Flash (MIT)** and **Qwen3-Coder-30B-A3B (Apache-2.0)** as drop-ins; **Qwen3.6-35B-A3B (Apache-2.0)** as the best-quality-that-fits (needs 3-bit for long context); **gpt-oss-20b (Apache-2.0)** as the fast, KV-roomy experimental pick.
- **Bigger ≠ better here.** The best agentic coders of 2026 (Qwen3-Coder-Next 80B-A3B, GLM-4.5-Air 106B, DeepSeek-V3.2 685B) **do not fit 32 GB** even though some have tiny active-param counts — because all weights must be **resident** (SSD at 1 GB/s rules out expert streaming). Fit is set by *total* params, speed by *active* params.
- **The real ceiling is swap/disk headroom, not RAM** **[VERIFIED, benchmarks/model-results.json]**: 32 GB is safe to ~22–23 GB resident *only with fresh swap after reboot*, otherwise ~17 GB. The 30B baseline already sits near that edge. This caps "go bigger" ambitions hard.
- **Two esh runtime gaps matter for coding:** (1) **structured/constrained output works only on the GGUF path** (llama-server json_schema/GBNF), **not on the fast MLX path**; (2) esh parses tool calls via a **prompt-based agent loop**, not models' **native tool-call templates** (GLM `glm47`, Qwen3-Coder, gpt-oss harmony). Neither blocks adoption, but both cap reliability/quality of agentic coding.
- **#1 risk = mlx-lm version compatibility.** esh's catalog already marks `qwen3.5-9b` **incompatible** (`create_attention_mask()` signature mismatch in the pinned mlx-lm) **[VERIFIED]**. Newer archs (Qwen3.6, GLM-4.7, gpt-oss MXFP4) may need a newer mlx-lm than esh provisions. **Verify load before any download.**

### Phase-6 recommendations (detail in §9)
1. **Best everyday coding model:** **GLM-4.7-Flash** `zai-org/GLM-4.7-Flash` MLX 4-bit — MoE 30B-A3B, MIT, ~16–18 GB, baseline-class speed, higher published coding/agentic scores, first-class tool-calling. *Alt / equally safe:* **Qwen3-Coder-30B-A3B-Instruct** (Apache-2.0, dedicated coder).
2. **Best high-quality coding model:** **Qwen3.6-35B-A3B** MLX (3-bit for 32k ctx, 4-bit if ctx ≤ ~8–16k) — newer/stronger, MoE speed, at the memory edge. *Verified-benchmark alt:* **Devstral Small 2 24B** (Apache-2.0, SWE-bench Verified 68.0 **[PUBLISHED-BENCHMARK, Mistral]**) but dense → slower.
3. **Best experimental max-capability (within 32 GB):** **gpt-oss-20b** (Apache-2.0, MoE 3.6B-active, MXFP4 ~11 GB → huge KV headroom, strong agentic/tool-calling) run at high reasoning. *Stretch:* Qwen3.6-35B-A3B at 3-bit/32k pushing the swap-safety edge (requires the memory-safety work in §8).

---

## 1. Current esh runtime capability audit

Source: full read-only code audit (`file:line` refs preserved). Audited on rc.35 working tree; deltas on `main` (rc.36) noted.

**Backends (4 distinct):**
- **MLX text** = **Python `mlx_lm` worker**, *not* native Swift. `MLXBackend` (`macos/Sources/EshMacRuntime/Backends/MLX/MLXBackend.swift:4`) spawns `python <bridge> mlx-serve` (`MLXWorker.swift:72`) and speaks newline-delimited JSON over stdio (persistent residency, `{op:init/generate/cancel/ping/shutdown}`). Bridge = `Tools/mlx_vlm_bridge.py` (2849 lines; requires `mlx_lm>=0.31.3`). Interpreter resolution: configured → `ESH_PYTHON` → bundled `python/bin/python3` → repo `.venv` → `/usr/bin/python3` (`RuntimePathResolver.swift:5–33`); managed venv host `EshManagedPythonHost.swift`. **On `main`/rc.36:** this is productized as the remote-consumable **EshMLXText** product (`Sources/EshMLXText/{MLXPersistentRuntime,MLXWorker}.swift`) + **MLXTextRuntimeProvisioner** (`Sources/EshMacCapabilities/`) managed-venv provisioning — same Python-worker mechanism, packaged for Studio.
- **Native mlx-swift** (vision/image/audio only): `EshVision` (MLXVLM), `EshImageGen` (StableDiffusion/InstructPix2Pix). *Text does not use native mlx-swift.*
- **GGUF in-process** (`EshLlamaCpp/LlamaCppEmbeddedBackend.swift`): llama.cpp C API, no subprocess, `Vendor/esh_llama.xcframework`. iOS path + macOS option. `GGML_METAL_NO_RESIDENCY=1` set for clean shutdown (`:178`). Default ctx 2048, `gpuLayers:999`.
- **GGUF spawned `llama-server`** (macOS): `macos/.../Backends/GGUF/LlamaCppBackend.swift` — OpenAI endpoint, `--jinja` (model's own chat template), `-c 8192`, `-ngl 999`.

**Model registry** (`Sources/EshCore/Services/RecommendedModelRegistry.swift:132–624`, 27 entries): MLX-4bit + GGUF-Q4_K_M, mostly Qwen2.5/3.5-era + DeepSeek-R1-distill + Phi/Gemma/Llama. Flagship default = `mistral-small-24b` (MLX 4-bit, 13.5 GB). Extreme-local default `esh run --best` = **`qwen-3-30b-a3b-mlx-4bit`** (experimental, measured 18 GB). Also a catalog-only `qwen-3-next-80b-a3b-iq2xs-gguf` (22 GB, *not installed*). Several `qwen-3-5-*` entries marked **`.incompatible`** (mlx-lm arch mismatch). Installed models surfaced separately via `LocalModelCatalog`.

**Quantization:** MLX catalog is 4-bit only; `ModelFitService.parseEffectiveBits` understands fp16…iq1 (`:214–229`). GGUF full K+IQ range. **TurboQuant** (`macos/.../Compression/TurboQuant/TurboQuantCompressor.swift`, bits 3.5) is a **prompt-cache/KV compressor + calibration** path (via `Tools/triattention_runtime.py`), *not* a weight repacker.

**Memory safety (4 layers):** estimator `weights=params·bits/8`, `runtime=weights·(1.18 gguf /1.22 mlx)+ctxOverhead` (`ModelMemoryEstimator.swift`); pre-download gate `ModelFitService` (budget = total − max(3, 20%); **measured peak overrides heuristic**; classes comfortable/fits/tight/unlikely); **live gate `MemorySafetyPreflight`** — swap-headroom-aware, blocks if `systemVolumeFreeGB < deficit + 3 GB` (reboot-prevention); per-provider `ResourceFit`.

**Scheduler / residency:** `RuntimeLifecycleManager` (actor) warm pool — acquire/release, `ensureResident` with load-dedup + **crash recovery**, LRU evict, `reclaimForPressure`, priority admission, truthful residency reporting. `SchedulerService v1` turns requests into decisions using fit + benchmark evidence. **"Scheduler v2" = design doc only** (`2_1_STAGE4_2_SCHEDULER_V2_DESIGN.md`); no v2 code.

**Context / KV / prompt cache:** per-model `contextWindow` metadata; enforced `n_ctx` (2048 embedded / 8192 server / native MLX). **MLX KV-cache quantization supported** (`kvMode raw/quantized`). **Prompt cache:** MLX build+load (`make/save/load_prompt_cache`); llama-server `cache_prompt:true`; GGUF has no esh prompt-cache export/import.

**Tool calling:** **prompt-based agent loop** (`AgentLoopService.swift` + `AgentToolService.swift`) — tools offered in a system-prompt list, model replies in one fenced block parsed by `AgentResponseParser`. Request-level `tools/toolChoice` plumbing exists. GGUF uses model jinja template; **native `tool_calls` emission not found** in any text path; MLX bridge has no function-call handling.

**Structured output:** **GGUF yes** (llama-server `response_format: json_schema` strict, else GBNF `grammar` — "M8"). **MLX no** (`MLXBackend.capabilityReport` lists `.responseFormatJsonSchema` unavailable — "constrained decoding not exposed yet").

**Cancellation / recovery:** all paths cooperative or subprocess-terminate, no orphans (`{op:cancel}` to worker; `Task.isCancelled` loops; stdin-EOF kill). Backend crash → `RuntimeLifecycleManager` unloads unhealthy runtime and reloads; 180 s worker startup watchdog.

**Benchmarks:** `esh benchmark lab`, `CalibrateCommand`, Python `benchmarks/{bench_mlx_lm.py,quality/suite*.py,hw_compute_mem.py,ssd_io_cold.py}`. **Recorded measurements (M1 Pro/32GB):** `benchmarks/model-results.json` (2026-10-07) — `Qwen3-30B-A3B-4bit` MLX **28.65 gen tok/s, 17.27 GB peak, swap-safe, interactive** ("REPRODUCED thesis"); `Qwen3-Next-80B-A3B IQ2_XS` llama.cpp **21.08 tok/s, 21.2 GB, swap-safe only post-reboot, quality "subtly wrong"**. `MODEL_BENCHMARK_LAB_REPORT.md`: 0.5B 324 t/s, 3B 106 t/s, 7B-distill 38 t/s, qwen3.5-9b **fails (mlx-lm incompat)**. **Machine safety finding:** true ceiling = internal-disk/swap headroom; safe ≤~22–23 GB only post-reboot else ~17 GB; Metal `recommendedMaxWorkingSetSize=26.8 GB`.

**Installed TEXT models on SSD (read-only):** `qwen3-30b-a3b-4bit` (16 G, MLX 4-bit, the `--best` default) · `qwen2.5-7b-instruct` (MLX, 3.2 G) · GGUF `llama-3-8b-web` Q8_0 (8 G) · GGUF `qwen2.5-{0.5b,1.5b}` Q4_K_M · tiny/partial `qwen3-0.6b`, `granite-4.0-micro`. No 80B present.

---

## 2. Ranked model shortlist (coding, fits 32 GB)

Ranked for **coding intelligence per fit**, baseline = installed `Qwen3-30B-A3B-4bit`. "Speed class" is **[ESTIMATE]** from active params unless a repo measurement exists.

| # | Model | Arch | Total/active | License | 4-bit size (res.) | Fit | Speed class | Headline coding score (vendor card) |
|---|---|---|---|---|---|---|---|---|
| 1 | **GLM-4.7-Flash** `zai-org/GLM-4.7-Flash` | MoE | 30B / ~3B | **MIT** | ~16–18 GB | Comfortable | ~baseline (30–40 t/s) | SWE-bench Verified **59.2**, LiveCodeBench v6 **64.0** [PUBLISHED-BENCHMARK — verify] |
| 2 | **Qwen3-Coder-30B-A3B-Instruct** | MoE | 30B / ~3.3B | **Apache-2.0** | ~17 GB | Comfortable | ~baseline | *No primary coding number for this exact size* (dedicated coder, strong tools) |
| 3 | **Qwen3.6-35B-A3B** | MoE | 35B / ~3B | **Apache-2.0** | 4-bit ~20–21 GB (tight) / 3-bit ~17 GB | Fits→Tight | ~baseline | SWE-bench Verified **73.4**, LiveCodeBench v6 **80.4**, Terminal-Bench 2.0 **51.5** [PUBLISHED-BENCHMARK — verify; card read via automated reader] |
| 4 | **gpt-oss-20b** `openai/gpt-oss-20b` | MoE | 21B / 3.6B | **Apache-2.0** | MXFP4 ~11.3 GB | Comfortable (big KV headroom) | fast (~40–55 t/s) [EST] | SWE-bench Verified **60.7** (high-reasoning) [PUBLISHED-BENCHMARK, OpenAI card] |
| 5 | **Devstral Small 2 24B** `mistralai/Devstral-Small-2-24B-Instruct-2512` | Dense | 24B | **Apache-2.0** | ~13–14 GB | Comfortable | slow (~10–14 t/s) [EST] | **SWE-bench Verified 68.0** [PUBLISHED-BENCHMARK, Mistral] — best *verified* <35B |
| 6 | **GLM-4-32B-0414** | Dense | 32B | **MIT** | ~17–18 GB | Fits | slow (~8–13 t/s) [EST] | BFCL-v3 69.6; SWE-bench 27–34 (older scaffolds) [PUBLISHED-BENCHMARK] |
| 7 | **Seed-OSS-36B-Instruct** (ByteDance) | Dense | 36B | **Apache-2.0** | Q4_K_M 21.76 GB [VERIFIED bartowski] | Tight (edge) | slow (~7–10 t/s) [EST] | LiveCodeBench v6 **67.4**, SWE-bench 56 (OpenHands) [PUBLISHED-BENCHMARK] |
| 8 | **DeepSeek-Coder-V2-Lite-Instruct** | MoE | 16B / 2.4B | DeepSeek license (verify) | Q4 ~10 GB | Comfortable | fastest (~45–60 t/s) [EST] | HumanEval 86.4, MBPP+ 61.8 [PUBLISHED-BENCHMARK]; 2024-era, no reasoning |
| 9 | **DeepSeek-R1-0528-Qwen3-8B** | Dense | 8B | **MIT** | ~5 GB | Comfortable (full ctx) | ~36 t/s [measured-class] | LiveCodeBench **60.5** [PUBLISHED-BENCHMARK]; reasoning latency |
| 10 | **Qwen3.8-27B** | Dense | 27B | **Apache-2.0** | ~15–17 GB | Fits | slow (~8–15 t/s) [EST] | very high card numbers — *flagged suspicious; verify on card* |

**Secondary / situational:** Mistral-Small-3.2-24B (Apache, general+code); CodeGeeX4-All-9B (82.3 HumanEval, 128k, 2024, non-MIT); GLM-Z1-32B-0414 (reasoning sibling of #6); DeepSeek-R1-Distill-Qwen-{14B,32B} (older, slow); Gemma 3 27B (weak at code — LiveCodeBench 29.7); Granite 4.0-H-Small (Apache, no primary coding number).

**Not practical (32 GB) — report-only:** Qwen3-Coder-Next 80B-A3B (official GGUF floor Q4_K_M **48.4 GB**; SWE-bench Verified 70.6 — strongest agentic, but overflows); GLM-4.5-Air 106B-A12B (4/3-bit = 44–56 GB); DeepSeek-V3.2 685B (SWE-bench Verified **70** [PUBLISHED-BENCHMARK]); GLM-4.6/4.7 ~355B; Llama 4 Scout 109B; Kimi-K2 ~1T; gpt-oss-120b; Devstral 2 123B; Cohere Command A 111B+. All confirm the user's prior thesis: **quantize-to-fit resident beats expert-streaming on a 1 GB/s SSD.**

---

## 3. Hardware feasibility matrix (M1 Pro / 32 GB)

Classes: **A Comfortable** (≤ ~18 GB resident, swap-safe without reboot) · **B Practical** (≤ ~22 GB, swap-safe *post-reboot* per the repo finding) · **C Experimental** (fits only at ≤3-bit and/or short ctx, or brushes the wired limit) · **D Not practical** (> 32 GB or forces SSD spill).

| Model | 4-bit resident [EST] | + KV @8k | + KV @32k | Class |
|---|---|---|---|---|
| gpt-oss-20b (MXFP4) | ~11.3 GB | ~12 GB | ~14 GB | **A** |
| Devstral Small 2 24B | ~13–14 GB | ~15 GB | ~18 GB | **A** |
| GLM-4.7-Flash 30B-A3B | ~16–18 GB | ~18 GB | ~20 GB | **A/B** |
| Qwen3-Coder-30B-A3B (baseline peer) | ~17 GB | 17.3 GB *(measured)* | ~20 GB | **A/B** |
| GLM-4-32B-0414 (dense) | ~17–18 GB | ~19 GB | ~22 GB | **B** |
| Qwen3.6-35B-A3B | 4-bit ~20–21 GB / 3-bit ~17 GB | ~22 / ~18 GB | ~24 / ~20 GB | **B** (4-bit) / **A-B** (3-bit) |
| Seed-OSS-36B (dense) | Q4 21.76 GB | ~23 GB | ~26 GB | **C** |
| Qwen3-Coder-Next 80B-A3B | Q4 48.4 GB | — | — | **D** |
| GLM-4.5-Air 106B-A12B | 44–56 GB | — | — | **D** |

KV-cache rule used: `bytes ≈ 2 · n_layers · n_kv_heads · head_dim · bytes/elem · tokens`. fp16 KV is fine ≤ ~8k for all A/B rows; **≥32k or the 36B dense row requires quantized KV (Q8/Q4)** to stay under the ~21–23 GB swap-safe ceiling. **Cold load ≈ size ÷ 1 GB/s** (17 GB ≈ 17 s; 21.8 GB ≈ ~22 s) — one-time per residency, mitigated by the warm pool.

---

## 4. Model / quantization comparison

- **MLX quantization** [VERIFIED]: default 4-bit, group size 64; supports 2/3/4/6/8-bit. **Flat 3-bit shows a clear quality drop** — usable mainly as *mixed-precision* (DWQ/OptiQ-style). esh catalog currently ships **4-bit only** (no 3-bit entries) → a **3-bit path is required** to fit Qwen3.6-35B-A3B at long context. `ModelFitService` already understands iq3/iq2 bit-math, so the gap is catalog + validated weights, not estimator.
- **GGUF quantization** [VERIFIED]: K-quants (Q4_K_M ≈ best balance, Q3_K_M) vs **IQ-quants** (IQ4_XS, IQ3_XXS, IQ2) which pack smaller at a quality cost. The repo's 80B IQ2_XS run confirms **IQ2 = "subtly wrong"** — fine for research, not for a coding default.
- **Per-GB coding value** (qualitative, [ESTIMATE]): the **3B-active MoEs win decisively** — they deliver 30B-class quality at ~3B-active decode speed in ~17 GB. Dense 24–36B models cost 1.5–3× the decode latency for comparable/again-vendor-claimed quality. **gpt-oss-20b** is the best *quality-per-GB-and-per-second* within 32 GB (fast + roomy + Apache-2.0 + verified OpenAI card).
- **KV precision** is a first-class knob here: quantized KV (already supported on MLX) is what makes 32k context affordable for the 30B-class without hitting the swap ceiling.

---

## 5. MLX vs GGUF recommendation

**Use both, by purpose — esh already has both paths:**

- **MLX (Python `mlx_lm` worker)** — *primary for interactive/agentic coding.* Pros: matches the installed stack, warm-pool residency, **prompt-cache build+load**, **KV-cache quantization**, fastest decode for MoE. Cons: **no constrained/structured output yet**, no native tool-call parsing, **arch support gated by mlx-lm version** (the real risk).
- **GGUF (`llama-server --jinja`)** — *use when you need structured output or exact native chat/tool templates.* Pros: **json_schema + GBNF grammar** (the only constrained-decoding path in esh), model's own jinja template (correct tool-call format), robust K/IQ quants. Cons: no esh prompt-cache export/import, spawned-server overhead, generally a touch slower than MLX for the same model on Metal.

**Net:** ship the everyday coder on **MLX 4-bit** for speed+residency; keep a **GGUF route** for tasks that demand strict JSON/tool-schema fidelity until MLX constrained decoding lands (§8). For a model whose agentic quality depends on native tool-call templates (GLM-4.7, Qwen3-Coder, gpt-oss), **GGUF+jinja currently preserves the template better than the MLX agent-loop** — a point to measure in §7.

---

## 6. Runtime compatibility gaps (evidence-based)

1. **mlx-lm arch compatibility [VERIFIED risk].** `qwen3.5-9b` is already `.incompatible` (`create_attention_mask()` mismatch). Qwen3.6/3.8, GLM-4.7, gpt-oss (MXFP4) may need newer `mlx_lm` than esh provisions (`>=0.31.3` today). **Must smoke-load before download/commit.**
2. **MLX constrained/structured output: absent.** Only GGUF has json_schema/GBNF. Agentic coding that relies on strict JSON tool args is less reliable on the fast path.
3. **Native tool-call parsing: absent.** esh uses a prompt/fenced-block agent loop, not models' native `tool_calls` (GLM `glm47`, Qwen3-Coder, gpt-oss harmony). Works, but leaves model-native agentic accuracy on the table.
4. **Catalog is stale.** No GLM-4.7-Flash, Qwen3-Coder-30B-A3B, Qwen3.6-35B-A3B, gpt-oss-20b, Devstral-2 entries; top entries are 2024–early-2026. `--best` default (30B-A3B) is good but upgradable.
5. **No MLX 3-bit path in catalog** — needed for the best-quality-that-fits (35B-A3B @ 32k).
6. **Memory ceiling is disk/swap, not RAM.** The 30B already sits near the safe edge; anything larger needs the swap-aware preflight to *require a reboot-fresh state* or refuse. Not a bug — a hard constraint on "go bigger."
7. **Speculative decoding not usable** [VERIFIED]: MLX draft path buggy (mlx-lm #1446); llama.cpp spec-decode is a *net loss* on unified memory (shared bandwidth). Do **not** invest here.

---

## 7. Coding benchmark plan (reproducible, apples-to-apples)

Reuse esh's own harness (`esh benchmark lab`, `benchmarks/bench_mlx_lm.py`, `benchmarks/quality/suite*.py`) and add task packs. **Baseline model = installed `qwen3-30b-a3b-4bit`** (no new weights for the baseline). Every candidate measured identically.

**Task packs (held-out, scored by rubric + executable checks):**
- **Swift/SwiftUI:** (a) fix a real compiler error in a small package; (b) implement a SwiftUI feature to spec; (c) refactor a component preserving behavior; (d) diagnose an async/actor concurrency bug. Score: builds? tests pass? diff minimality.
- **TypeScript/Next.js:** (a) build a functional component; (b) fix a failing test; (c) modify an existing Next.js route. Score: `tsc` clean, tests pass.
- **Agentic:** repo-structure interpretation → tool selection → valid tool calls → multi-file edit → **recover from one injected failed op**. Score: tool-call validity %, task completion, recovery success.
- **Long context:** locate relevant code across N files and honor an existing architectural constraint. Score: correct-file localization, constraint adherence.

**Metrics (all captured by the harness):** correctness, tests-passing, tool-call validity %, TTFT, decode tok/s, **peak memory + swap-safety flag**, context reliability, stability (crash/incompat). Report **measured** only; carry vendor card numbers separately as claims.

**Protocol:** quiet system, post-reboot for the ≥20 GB candidates (per the swap finding), 3 runs/metric, median; identical prompts/templates; MLX vs GGUF variant where both exist (to measure the template/structured-output effect from §5).

---

## 8. Proposed esh improvements (ranked; evidence-gated, not yet approved)

1. **Add a validated 3B-active MoE coder to the catalog** (GLM-4.7-Flash and/or Qwen3-Coder-30B-A3B) as the new recommended coding default once smoke-loaded — *catalog + fit metadata only, no runtime change.* **Low risk, highest payoff.**
2. **Verify/raise the provisioned `mlx_lm` version** to one that loads the 2026 archs, and record a compatibility matrix (which arch loads on which mlx-lm). *Gates everything MLX.*
3. **MLX constrained decoding (structured output)** — expose logit/grammar constraints in the bridge so JSON-schema tool args work on the fast path (closes gap §6.2). Medium effort.
4. **Native tool-call parsing** per model template (glm47 / qwen3-coder / harmony) alongside the agent loop (closes §6.3). Medium effort.
5. **MLX 3-bit (mixed-precision) path** + catalog entries, to fit 35B-A3B @ 32k (closes §6.5). Small-medium.
6. **Keep speculative decoding OUT** — evidence says it regresses on unified memory. Document the decision.
7. **(Already strong) warm pool + swap-aware preflight** — no change needed; lean on them for the ≥20 GB candidates.

---

## 9. Risks & tradeoffs

- **Vendor benchmark reliability.** Most 2026 coder numbers are vendor-card self-reports; some third-party/SEO pages were **fabricated** and excluded. Qwen3.6/3.8 card decimals were read by an automated reader — **verify on the card before quoting**. Treat §2 scores as claims to confirm via §7.
- **mlx-lm incompatibility** could block the best MoE picks (precedent: qwen3.5-9b). Mitigation: smoke-load first (§10).
- **Memory edge.** 30B-class + long ctx brushes the swap-safe ceiling; needs reboot-fresh state or refusal. Larger-than-30B dense (Seed-OSS-36B) is tight and slow.
- **License.** GLM-4.7-Flash (MIT), Qwen3-Coder/Qwen3.6 (Apache-2.0), gpt-oss/Devstral (Apache-2.0) are all **commercial-safe**. DeepSeek-Coder-V2-Lite and some GLM-0414/CodeGeeX weights carry non-MIT terms — verify before any commercial default.
- **Dense vs MoE.** Dense 24–36B *fit* but decode 2–4× slower than the 3B-active MoEs — poor interactive UX despite comparable quality.
- **Structured-output split.** Until MLX constrained decoding lands, strict-JSON agentic flows are more reliable on GGUF, which is slower — a real everyday tradeoff.
- **Doing nothing** is a legitimate option: the installed 30B-A3B is already a strong, measured, swap-safe coder. The upside of switching is better *agentic/coding scores* and MIT licensing, not a fit/speed change.

---

## 10. Recommended first controlled experiment

**A compatibility + head-to-head smoke test — zero commitment, minimal download, gated for your approval.**

1. **mlx-lm load smoke test (no benchmark):** on the esh-provisioned Python, attempt to load **GLM-4.7-Flash 4-bit** and **Qwen3-Coder-30B-A3B 4-bit** (and, if easy, **gpt-oss-20b**). Confirm: model loads, chat template applies, 10-token generation works, residency reports, cancel works. **This de-risks gap §6.1 before any real benchmarking.** (Requires downloading those weights to the SSD — **needs your approval**.)
2. If load succeeds, **run the §7 baseline pack** comparing the loaded candidate(s) vs the installed `qwen3-30b-a3b-4bit`, measuring correctness + tool-call validity + tok/s + peak memory/swap-safety. Post-reboot for ≥20 GB.
3. Decide a new `--best` coding default from **measured** results, not card claims.

**If you prefer zero downloads first:** I can instead (a) verify the provisioned `mlx_lm` version and its supported archs purely from installed packages, and (b) dry-run the §7 harness against the already-installed 30B baseline to validate the task packs — then bring you a go/no-go for step 1.

---

## Stop point
Per your instructions this is research only. **I will not download weights, run new-weight benchmarks, change the catalog/runtime, or merge/publish anything until you approve.** Awaiting your call on §10 (and whether to keep this report in `docs/research/` under version control).

### Sources
Full per-model source URLs are in the committed sibling folder `local-coding-intelligence-2026-10/` (`research-qwen.md`, `research-deepseek-glm.md`, `research-others-feasibility.md`). esh claims are cited inline by `file:line` from the rc.35 working tree; `main`/rc.36 deltas verified against `origin/main = e40d4ad`.
