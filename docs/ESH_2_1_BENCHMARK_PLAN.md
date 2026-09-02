# esh 2.1 — Benchmark Plan

**Purpose:** give the 2.1 ExecutionPlan Scheduler and the Local Evidence Layer trustworthy,
reproducible, on-device measurements so `Auto` decisions and model recommendations are grounded in what
actually works on **this** Mac — not generic estimates or upstream marketing.

Builds on the 2.0 Benchmark Lab (`ProductionBenchmarkRunner` / `BenchmarkService` /
`ModelBenchmarkEvidence`, persisted under `~/.esh/benchmarks`). 2.1 expands *coverage*, *fields*, and
*consumption by the scheduler*.

## Governing rules
- **Discovery source ≠ authority.** Upstream (Hugging Face, llama.cpp, MLX, LM Studio as discovery)
  identifies *candidates* and their claimed capabilities. **esh benchmarks decide esh defaults.**
- **Never fabricate numbers.** A metric is either measured (with provenance) or absent. No estimates
  presented as measurements.
- **No strategy/model enters `Auto` without local evidence** passing correctness/quality + stability
  gates. Newer ≠ better.
- **Local-only.** No benchmark upload or telemetry by default. Export/reset are user-controlled.

## Hardware memory classes
Benchmarks and recommendations are bucketed by unified-memory class (the dominant Apple-Silicon
constraint): **≤8 GB · 16 GB · 24 GB · 32–36 GB · 48–64 GB · 96 GB+**. Each result records the exact
chip + memory so evidence is never applied across classes without justification.

## Task/use-case profiles
`fast · general · coding · reasoning · tools · structured output · vision · long context · low memory ·
maximum quality`. A model may be strong on one profile and weak on another; evidence is per-profile.

## What every benchmark run records (provenance)
Model repo **exact revision/commit** · quantization/format · backend + runtime version (mlx-lm /
llama.cpp tag / Apple) · esh version · chip + memory class · macOS version · context length tested ·
optimizer/profile · **cold vs warm** state · free disk / storage location (internal vs external SSD).

## Metrics
- **Latency:** TTFT (time-to-first-token), and for speech TTFA (time-to-first-audio).
- **Throughput:** prefill tok/s, decode tok/s.
- **Load:** cold model-load time; warm reuse time; residency truthfulness.
- **Memory:** peak + steady resident; KV growth vs context; headroom vs class budget.
- **Cache:** prompt/prefix-cache hit benefit; KV-quant effect on speed/quality/memory.
- **Stability:** OOM, crashes, worker restarts, timeouts, unexpected-EOS/runaway, malformed tool calls,
  structured-output failures, cancellation reliability.
- **Quality evidence:** task-appropriate correctness checks (e.g. constrained-JSON validity, code
  compiles/executes on a fixed set, reasoning exact-match on a small curated set). Quality is
  *evidence*, never a fabricated score.

## Speech benchmarks (feeds M12/M13)
Cold/warm STT latency; cold/warm TTFA; total TTS time; resident memory with a large LLM co-resident;
repeated-turn latency; voice/language switching cost; long-text streaming; cancellation/recovery.
**Baseline measured on M1 Pro / 32 GB, stable 2.0.0** (`scratchpad/21_proofs.md`):
- TTS (pocket-tts): cold **1.28 s** → warm **~0.5 s** (mlx-audio caches weights; residual per-call
  overhead is the target).
- STT (parakeet): **6.3 → 5.0 → 4.0 s** across consecutive calls — barely warms; **the primary
  voice-latency bottleneck** and the strongest justification for a persistent STT runtime.

## Optimization/technique benchmarks (feeds M17)
Each candidate technique (KV quant, rotating cache, prompt/prefix cache, speculative/draft decoding,
prefill/batching/Metal tuning) runs the pipeline: **candidate → benchmark → correctness/quality test →
hardware/workload profile → eligible or rejected from `Auto`**. Record speed delta, quality delta,
memory delta, and stability. GGUF draft-model speculative decoding is *available in the bundled
`llama-server`* (`--hf-repo-draft`/`--cache-type-*-draft`) and is a first benchmark candidate.

## Evidence lifecycle (Local Evidence Layer, M14)
- **Sample thresholds / confidence:** a decision uses local evidence only above a minimum sample count;
  below that, fall back to curated/estimated with lower confidence, surfaced honestly.
- **Freshness / invalidation:** evidence is invalidated when the model revision, backend/runtime
  version, esh version, or optimizer changes; stale evidence is down-weighted.
- **Outliers:** thermal/pressure spikes and first-run shader-compile costs are detected and excluded or
  flagged (e.g. the one-time GGUF Metal shader compile).
- **Provenance & privacy:** every datum carries how/when it was measured; all local; export/reset
  available; no external sharing by default.
- **Consumption:** Scheduler v2 reads local evidence first, curated/upstream second; the Web/CLI
  "Why this execution plan?" cites the evidence used and marks **measured-on-this-Mac vs estimated**.

## Reproducibility & harness
- Deterministic seeds where supported; fixed prompt sets per profile; warm/cold runs separated.
- Results are re-runnable via `esh` benchmark commands; raw results persisted with provenance.
- CI runs a *smoke-scale* benchmark (tiny models, correctness + no-runaway + finish-reason) to catch
  regressions; full hardware-class matrices are run on real machines, not CI.

## Deliverable of the benchmark program
A per-Mac evidence table that, combined with curated + upstream candidate data, lets the scheduler pick
an ExecutionPlan and explain it — and lets the Model Browser show **estimated vs measured** honestly.
