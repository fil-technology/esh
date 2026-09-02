# esh 2.1 — North Star

> **The central question esh 2.1 must answer:**
> *"What is the best way to execute this capability on this Mac, right now?"* —
> not merely *"which model should I use?"*

esh 2.0 is a correct, self-contained local model **orchestrator**: it installs/validates models, runs
MLX + GGUF (bundled `llama-server`) + Apple Foundation Models, keeps a model resident, routes `Auto`
with a rationale, estimates hardware fit, and exposes a Web/CLI/OpenAI-Anthropic surface — all locally,
privately, notarized.

esh 2.1 makes esh **adaptive**: it turns an *intent* into the *best executable plan for the current
machine state*, and it gets smarter with use by learning what actually works on **this** Mac.

## The shift: model selection → execution planning

Today `Auto` chooses a **model**. In 2.1 `Auto` chooses an **ExecutionPlan**:

```
intent  →  ExecutionPlan
           model · backend · format/quantization · runtime
           residency decision · KV policy · prompt-cache policy
           context policy · reasoning budget · speculative strategy
           memory actions · speech lifecycle (if applicable)
```

A caller expresses *what they need under what constraints* —

```
coding · tools required · high quality · ~40K context · interactive latency · local-only
```

— and esh decides *how to execute it well*, grounded in: hardware + unified-memory state, resident and
installed models, task/capability requirements, **benchmark evidence measured on this Mac**, observed
runtime reliability, cold/warm cost, cache state, optimizer performance, and privacy constraints.

Normal users still see **`Auto`**. Experts can inspect **"Why this execution plan?"** — the same
"Why this model?" idea extended to the full plan, always derived from the real decision and evidence,
never a post-hoc rationalization.

## What makes esh *smarter than a local model runner*

1. **Execution-plan scheduling** — one coherent decision over model/backend/quant/runtime/KV/cache/
   context/speculative/memory, not a series of disconnected toggles.
2. **Local empirical calibration** — esh accumulates on-device evidence (TTFT, prefill/decode speed,
   load cost, memory, KV growth, cache benefit, failures/OOM, tool/structured-output/cancel
   reliability) and lets measured local truth override generic estimates *only when justified*.
3. **Truthful residency across modalities** — persistent LLM **and** speech runtimes, so warm really
   means warm (STT today re-inits at ~4–6 s/call; that is the first thing to fix).
4. **Adaptive optimization** — KV/cache/speculative/runtime techniques enter `Auto` only after passing
   *benchmark + correctness/quality + hardware-profile* gates. Newer ≠ better by default.
5. **Explainable, hardware-specific defaults** — the recommendation for a 16 GB M2 and a 96 GB M3 Max
   differ because esh *measured* the difference, and can say why.

## Principles

- **Auto is the product; inspectability is the trust.** Simple by default, fully explainable on demand.
- **Benchmark before believing.** Upstream claims identify *candidates*; esh benchmarks choose
  *defaults*. Never fabricate numbers; never promote a strategy to `Auto` without local evidence.
- **Truthful over impressive.** Residency, "measured vs estimated", finish reasons, and known-broken
  models are reported honestly.
- **Local-first & private.** Local observations stay local; no telemetry, prompt upload, or benchmark
  upload by default.
- **Do one thing extremely well.** esh is the execution engine, not an agent framework.

## The esh / Ashex boundary (unchanged, reaffirmed)

- **esh owns:** models, runtimes, inference, optimization, hardware awareness, Model Fit, benchmarking,
  **execution planning**, runtime lifecycle, caches, inference-context planning, STT/TTS, capabilities
  and APIs.
- **Ashex owns:** goals, planning, autonomous loops, personal/semantic memory, durable jobs, Mac
  actions, browser/computer control, permissions, personality. **esh 2.1 must not grow agent semantics.**

## 2.0 compatibility baseline (what 2.1 must preserve)

`v2.0.0` is the stable compatibility baseline. 2.1 must not casually break:
- native `/v1` request/response schemas + `schemaVersion` strings (and OpenAI/Anthropic adapters);
- `EshConfig` keys and defaults;
- model storage layout (`FileModelStore`, external-SSD `storage.json`);
- CLI machine-readable (`--json`) outputs;
- Web client behavior and the self-contained/no-external-host guarantee.

Breaking changes require explicit versioning/migration. 2.0 bug fixes stay separate from 2.1 work.

## What esh 2.1 is *not*

- Not "2.0 + more settings + more models + random features."
- Not a RAG/long-term-memory system (inference-context planning only; semantic memory is Ashex).
- Not an agent/tool-orchestration framework.
- Not a remote/multi-user service by default (remote access is research-only, security-first).

## Definition of success

A normal user thinks: *"This is just my private AI on my Mac, and it's fast and it just works."*
An expert thinks: *"esh is choosing the best execution plan my hardware can run, and it can prove why."*
