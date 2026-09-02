# esh 2.1 — Risk Analysis & Feature Prioritization

## Part 1 — Risk analysis

### Complexity
- **ExecutionPlan scheduler (M15)** risks over-engineering. *Mitigation:* the audit shows the decision
  object already carries backend+profile+rationale — 2.1 is mostly *wiring* (scheduler↔pool) + promoting
  a type, not a rewrite. Keep `Auto` a single decision; expose complexity only via "Why this plan?".
- **Multi-model pipelines (M19)** are the highest complexity-for-value risk. *Mitigation:* benchmark-
  first; always compare vs "just use the stronger model"; reject without a measured net win.
- **Optimizer matrix explosion** (backend × quant × KV × spec × context). *Mitigation:* strategies stay
  *data* behind benchmark gates; only techniques with local evidence enter `Auto`.

### Memory (unified-memory exhaustion)
- Persistent **speech + large LLM co-residency** (M12) can exhaust unified memory. *Mitigation:* speech
  registers with `RuntimeLifecycleManager` (reservations via `ttsReserveGB`, pressure eviction); measure
  co-resident peak before enabling by default.
- **KV-quant vs spec-decode exclusivity** (MLX: quantized/rotating caches aren't trimmable → break
  speculative decoding). *Mitigation:* the planner must treat these as mutually exclusive and choose per
  workload with evidence.
- Speculative decoding adds a **draft model in memory**; net win can be negative on MoE/tight memory.
  *Mitigation:* fit-aware + benchmark-gated.

### Compatibility (the 2.0 baseline)
- Breaking `esh.infer.*.v1`, `EshConfig`, storage layout, or CLI `--json` would break Ashex and existing
  users. *Mitigation:* additive optional fields, preserved defaults, explicit versioning+migration for
  any true break; every RC re-runs the 2.0 packaged/notarized/no-Homebrew validation.
- **llama.cpp bump past b8660** changes spec-decode flags (`--draft-max`→`--spec-draft-n-max`).
  *Mitigation:* internal to `LlamaServerProcess`; pin a new tag, migrate flags, re-validate packaging.

### Maintenance
- **mlx-lm / mlx-vlm churn**: transformers-v5 pin conflict across one venv, `generate()` positional
  drift, ~0.5.0 attention-signature change, fast 0.6.x/0.7.0 releases. *Mitigation:* pin versions in
  `python-requirements.txt`; a bridge contract test; gate on `DeprecationWarning`; the mlx-vlm 0.5.0
  contract test esh already has is the model.
- **Fragmented evidence stores (3)** raise maintenance cost. *Mitigation:* M14 consolidation.
- **Fabricated upstream benchmarks** could mislead defaults. *Mitigation:* never adopt an unbenchmarked
  claim; measured-on-this-Mac evidence is authoritative.

### Product value
- Risk of "2.0 + more settings/models." *Mitigation:* every milestone must move the North Star metric
  (better intent→execution plan), not add surface. Reject features that don't.
- **Provenance risk** (e.g. Muse Glimmer / `meta-models` unverified). *Mitigation:* esh benchmarks +
  known-broken gating; never bundle/recommend on unverified provenance.

### Security (M22, research-only)
- Remote runtime exposure is a serious attack surface. *Mitigation:* research + threat model only; no
  LAN/WAN by default; nothing merges without a convincing security design.

## Part 2 — Feature prioritization matrix

### ✅ Proven / Implement Soon (evidence supports it)
| Item | Evidence |
|---|---|
| **Persistent STT runtime** (M12) | Measured 4–6 s/call, barely warms — clear, local, high-impact. |
| **Scheduler v2 → ExecutionPlan + warm-pool loop** (M15) | Audit: decision already carries backend+profile; seam is wiring. |
| **Unified Local Evidence Layer** (M14) | Three fragmented stores today; everything adaptive depends on one truthful store. |
| **Unified per-model record (estimated vs measured)** | Audit: only joined inside `score()`; UX needs it explicit. |
| **Speech `SpeechBackend` protocol + pool integration** | Audit: speech is entirely outside the system; `ttsReserveGB` hook already anticipates it. |

### 🔬 Benchmark First (promising; must prove local value)
| Item | Why benchmark |
|---|---|
| **GGUF n-gram / prompt-lookahead speculative** | No draft model; available in newer llama.cpp; cheapest speculative candidate. |
| **GGUF draft-model + EAGLE3 speculative** | Flags in b8660 (draft) / EAGLE3 in newer; speedups all `[CLAIMED]`; MoE-weak. |
| **MLX draft-model spec (mlx-lm) / MTP-DFlash (mlx-vlm)** | Available; KV-trim exclusivity + MoE caveats; measure net win. |
| **KV quantization (q8_0 K etc.)** | Common "near-free" win claimed; verify quality/speed/memory per model. |
| **Persistent prompt-cache reuse across turns** | Mature on both backends; measure real hit benefit. |
| **Streaming voice pipeline / barge-in** (M13) | Building blocks exist; perceived-latency must be measured. |
| **Muse-Glimmer-30B (and other 30B VLMs)** | Real MLX build; provenance + quality unverified — candidate only. |
| **Multi-model pipelines** (M19) | Only if measured net win vs the stronger single model. |
| **Apple FM `LanguageModel`/MLXLanguageModel integration** | New surface; evaluate value vs added dependency. |

### 🔭 Research Only (interesting, not ready)
| Item | Note |
|---|---|
| **Remote esh runtime** (M22) | Security architecture first; no default exposure. |
| **Context Intelligence beyond cache/truncation** (M18) | Keep to inference-context; avoid drifting into RAG/memory. |
| **Backend/optimizer/speech extension registries** (M21) | Open only the justified seams; avoid a generic plugin platform. |

### ❌ Reject (doesn't belong / doesn't justify complexity)
| Item | Why |
|---|---|
| Agent loops / autonomy / durable jobs / semantic memory | Ashex owns these; esh must stay the execution engine. |
| Generic plugin ecosystem for abstraction's sake | Cost without product value; open specific seams instead. |
| Multi-user/cloud service by default | Contradicts local-first/privacy; security risk. |
| External telemetry / benchmark upload by default | Violates privacy baseline; any sharing is separate opt-in. |
| Adopting upstream defaults on `[CLAIMED]` numbers | Fabricated-benchmark risk; esh benchmarks decide. |
| Bundling/recommending unverified-provenance models | e.g. anything on unconfirmed `meta-models` authenticity. |
