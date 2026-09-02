# esh 2.1 — Roadmap

**Theme:** turn esh from a correct local model *runner* into an adaptive local *execution engine* —
intent → best ExecutionPlan for this Mac — grounded in on-device evidence, with truthful residency
across LLM **and** speech. See `ESH_2_1_NORTH_STAR.md`, `ESH_2_1_ARCHITECTURE.md`,
`ESH_2_1_BENCHMARK_PLAN.md`, `ESH_2_1_RESEARCH_REPORT.md`.

**Rule for every milestone:** audit → implement coherent scope → tests → build/test + benchmark →
docs/changelog → commit → release when user-facing → verify CI/release → record evidence. Nothing enters
`Auto` without local benchmark + correctness/quality + stability evidence. Preserve the 2.0
compatibility baseline (§0). Never fabricate numbers.

## M0 — Protect the 2.0 baseline (continuous)
**Objective:** 2.1 development never regresses stable 2.0. **Work:** document the 2.0 compatibility
contract (v1 schemas, config keys, storage layout, CLI `--json`, Web self-containment); keep 2.0 bug
fixes on a separate track; additive-only schema changes with migration for anything breaking.
**Gate:** every 2.1 RC re-runs the packaged/notarized + no-Homebrew validation used for 2.0.

## M12 — Persistent Speech Runtime  *(first engineering priority)*
**Objective:** truthful warm STT/TTS under `RuntimeLifecycleManager` via a new `SpeechBackend` protocol.
**Why (measured):** STT is the real bottleneck — **6.3→5.0→4.0 s/call**, barely warms; TTS already warms
(1.28 s→~0.5 s), so its win is shared lifecycle + first-audio, not "reload." **Work:** `SpeechBackend`
(STT+TTS); persistent workers registered with the pool (warm/evict/pressure/reserve via the existing
`ttsReserveGB` hook); cancellation; crash recovery; model/voice/language switching; coexistence with a
large resident LLM. **Benchmark:** cold/warm STT + TTS, TTFA, resident memory with LLM co-resident,
repeated turns, switching cost, cancellation/recovery. **Non-goals:** conversational streaming (M13);
agentic voice (Ashex). **Gate:** warm STT materially faster than cold; residency truthful (no per-call
reload); memory bounded with a 7B+ LLM resident; speech reservation respected.

## M13 — Voice 2.1 (conversational)
**Objective:** local voice that feels immediate: streaming STT → early LLM start → sentence/streaming
TTS, with barge-in. **Work:** streaming STT + partial transcripts (parakeet `transcribe_stream` /
whisper `--vad`), VAD + turn detection, interruption-safe TTS, latency hiding, prewarming, echo/
conversation state, seamless text↔voice. **Benchmark:** perceived latency (mic→first audio), barge-in
responsiveness, long-text streaming, multilingual. **Non-goals:** agent semantics; put no autonomy in
esh. **Gate:** measured perceived latency below an agreed target; barge-in reliably interrupts.

## M14 — Local Evidence Layer
**Objective:** unify the three current evidence stores (Model Benchmark Lab, OptimizationProfileStore,
legacy BenchmarkService) into one provenance-tracked, confidence-weighted store keyed by
`(model-rev, runtime, hardware class, strategy, workload)`. **Work:** sample thresholds, freshness/
invalidation on model/runtime/esh/optimizer change, outlier handling (thermal, first-run shader
compile), export/reset, privacy (local-only). **Benchmark:** correctness of invalidation + confidence.
**Gate:** scheduler consumes it; local evidence overrides estimates only above threshold; UI shows
measured-vs-estimated honestly.

## M15 — Scheduler v2 (ExecutionPlan)
**Objective:** promote `SchedulerDecision`/`ExecutionProfile` to a first-class **`ExecutionPlan`** and
**close the loop with the warm pool** (read live residency/pressure; emit acquire/prewarm/evict/reserve
actions). Fold OptimizationPlanner choices into one plan. **Work:** `ExecutionPlan` type (additive to
v1 schemas); scheduler↔lifecycle wiring; unified per-model `ModelKnowledge` (estimate+measured).
**Benchmark:** plan quality vs 2.0 static defaults on several workloads (latency/memory/quality).
**Gate:** several workloads where the plan is evidence-backed and beats or ties naive defaults with less
memory, without crossing quality thresholds; full rationale for every field.

## M16 — Benchmark Lab 2.1
**Objective:** expand hardware-class × profile coverage and record full provenance (see Benchmark Plan).
**Work:** memory classes ≤8…96+ GB; profiles fast/general/coding/reasoning/tools/structured/vision/
long-context/low-memory/max-quality; discovery ≠ authority (upstream identifies candidates, esh
benchmarks decide). Candidate models incl. large 30B-class MLX/GGUF builds **remain candidates, not
predetermined winners.** **Gate:** reproducible datasets with provenance feed M14/M15; no fabricated
numbers.

## M17 — Adaptive Optimization
**Objective:** let `Auto` select KV/cache/speculative/runtime strategies per hardware+workload, behind
benchmark gates. **Candidates (from research, all benchmark-first):** GGUF **speculative decoding** —
draft-model flags already in the bundled `llama-server`; **n-gram/prompt-lookahead** (no second model)
and **EAGLE3** available in newer llama.cpp; **KV quantization** (q8_0 K); **persistent prompt-cache
reuse** (`--slot-save-path`, `--cache-reuse`). MLX-side speculative/KV per the MLX research.
**Work:** extend `OptimizationPlanner` to plan the `speculative`/`runtime` categories (today only
kv-cache/prompt-cache); wire `spec.*` strategies (currently inert placeholders). If it requires bumping
llama.cpp past b8660, re-validate packaging (flags changed: `--draft-max`→`--spec-draft-n-max`).
**Gate:** each technique passes candidate→benchmark→correctness/quality→hardware-profile before entering
`Auto`; newer ≠ better.

## M18 — Context Intelligence
**Objective:** inference-context planning (not RAG/memory): requested-context capability, memory/KV
prediction, prompt-cache selection/reuse, truncation policy, warn-before-history-loss. **Non-goals:**
long-term/semantic/personal memory (Ashex). **Gate:** measured KV/memory prediction accuracy; no
silent history loss.

## M19 — Multi-model experiments (benchmark-first)
**Objective:** evaluate router / draft+refine / specialist (vision-OCR, tool-specialist) pipelines
**always vs. "just use the stronger model directly."** **Gate:** ship only pipelines with measured net
win (latency/quality/memory/reliability); reject complexity without gains.

## M20 — Runtime priorities / background work
**Objective:** foreground interactive QoS vs background (summarization, benchmarks, prewarm, STT/TTS):
priorities, resource reservations, pause/preempt, load scheduling. (Builds on the pool's existing
priority/concurrency.) **Gate:** interactive latency protected under background load; no uncontrolled
memory growth.

## M21 — Extensibility / living intelligence data
**Objective:** open the justified extension seams (backend resolution registration-driven; SpeechBackend
registry; per-category optimizer planning) and make catalog/compatibility/recommendation/optimization/
known-broken data **independently versioned** with provenance, integrity, rollback, offline-safe,
failure-isolated. **Non-goals:** generic plugin ecosystem for its own sake. **Gate:** adding a backend/
optimizer/speech engine needs data + a registered factory, not core surgery; a bad catalog update can't
brick local inference.

## M22 — Remote runtime (research only)
**Objective:** research secure access to a Mac's esh from another device (pairing, auth, encryption,
device trust, NAT/tunnels, permissions, audit). **Do not** expose LAN/WAN by default or implement until
the security architecture is convincing. **Gate:** threat model + design review before any prototype
merges.

## Sequencing rationale
Speech first (M12/M13) because it's the strongest measured pain (STT 4–6 s) and came from real 2.0 use;
then the evidence layer (M14) that everything adaptive depends on; then Scheduler v2 (M15) which the
audit shows is largely a *wiring* job (the decision object already carries backend+profile); Benchmark
Lab (M16) and Adaptive Optimization (M17) build the measured knowledge that makes `Auto` genuinely
smart; M18–M22 extend and harden. Order may adjust if benchmarks say so.
