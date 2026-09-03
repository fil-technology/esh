# esh 2.1 — Stage 4.2 design: performance-aware Auto (Scheduler v2)

Status: **design only** (no scoring rewrite yet), per the Stage 4.2 brief. Goal: let Auto choose a
provider/model that is *actually practical on this Mac* by consuming capability-specific performance
evidence — because **memory fit ≠ useful performance** (Z-Image-Turbo 6B: Comfortable in RAM, but ~215 s/
image at 1024²).

## 1. Current state (what exists)
- **`SchedulerService.decide(request, root, host)`** ranks **LLM** candidates from `RecommendedModelRegistry`
  using `ModelBenchmarkLabStore` (`ModelBenchmarkEvidence`: quality probes + tokens/sec) and `ModelFitService`.
  It selects a *text model*; it has no notion of image/video/audio operations.
- **Capability execution** (`/v1/execute`) resolves a model via **`CapabilityModelResolver`** (picks an
  installed model whose declared `capabilities` match), NOT via `SchedulerService`. Providers then run.
- **Media performance evidence already exists but is siloed**: `ImageGenerationBenchmark` +
  `ImageGenerationBenchmarkStore` (cold/warm/sec-per-image/peak/resolution/validity/stability +
  `measuredUnderMemoryPressure`/`note`), and the Stage 4.1 `image-upscale-benchmarks.json` (scale/cold/warm/
  peak/quality/experimental). Neither is consulted at selection time.
- **`ExecutionPlan`** already carries `rationale`, `evidenceBacked`, and per-step `ExecutionProfile` — the
  natural place to record *why* a perf-aware choice was made.

## 2. The gap
There is no shared shape for "measured cost of one operation of capability X by provider/model M at config
C on this Mac", and no capability-aware ranking step that consumes it. So Auto cannot prefer a 30 s/image
model over a 215 s/image one, or prefer 512² when 1024² is impractical.

## 3. Proposed unified evidence model (additive)
A single normalized record every capability runner can emit and every selector can read:

```
CapabilityPerformanceEvidence {
  capability: CapabilityID            // image.generate, image.upscale, video.understand, audio.diarize, language.generate…
  providerID: String                  // "image-generation", "image-upscale", …
  modelID: String?                    // resolved model / backend identity
  config: [String: JSONValue]         // capability-specific knobs that affect cost: {resolution, steps, scale, …}
  coldMs: Double?; warmMs: Double?     // load+first vs steady-state
  secondsPerUnit: Double?             // seconds/image, seconds/second-of-video, seconds/audio-minute…
  unit: String                        // "image" | "video-second" | "audio-minute" | "1k-tokens"
  peakMemoryMB: Double?; residentMemoryMB: Double?
  reliability: Double?                // 0…1 (validity rate / stable flag)
  measuredUnderMemoryPressure: Bool   // not recommendation-grade when true
  experimental: Bool                  // never auto-selected while true (e.g. SeedVR2)
  provenance: BenchmarkProvenance     // hardware, runtime, revision, esh version, date
}
```

- **Adapters, not migrations**: keep the existing typed stores; add thin adapters
  (`ImageGenerationBenchmark → CapabilityPerformanceEvidence`, upscale JSON → …, `ModelBenchmarkEvidence →
  …` for LLM tokens/sec). One read-only accessor `CapabilityEvidenceIndex(root:)` merges them and answers
  `best(capability:, config:, prefer:)` and `all(capability:)`.
- **Config-keyed**: evidence is looked up by capability + the cost-driving config (e.g. resolution) so a
  512² query uses 512² evidence, not the 1024² sample.

## 4. How Auto consumes it (capability-aware selection — later slice)
Add a `CapabilityScheduler.select(capability, inputs, output, options, latencyPreference, host, root)` that:
1. Enumerates installed provider+model candidates for the capability (registry + resolver).
2. For each, looks up `CapabilityPerformanceEvidence` at the requested config; computes **fit** (memory) via
   the capability's fit service.
3. Ranks by a small, explicit rule (NOT a giant score):
   - drop `experimental` and fit-`unsupported`;
   - if `latencyPreference == interactive`, require `secondsPerUnit ≤ threshold(capability, host)` when
     evidence exists; prefer the fastest that still meets a quality/reliability floor;
   - no evidence → fall back to today's fit-first behavior (honest: mark `evidenceBacked=false`).
4. Emits the choice into the `ExecutionPlan.rationale` ("chose X: measured 51 s/image @512² vs 215 s @1024²;
   memory Comfortable") and sets `evidenceBacked=true`.

The **thresholds** encode "memory fit ≠ useful perf": e.g. interactive image ≤ ~60 s/image on this class of
Mac; above it, prefer a lighter model or a smaller resolution, or warn.

## 5. Interaction points (minimal, additive)
- `CapabilityModelResolver` gains an optional evidence-aware path (kept behind the new scheduler; the plain
  capability match remains the fallback).
- `ExecutionPlan` needs no schema change — it already has `rationale`/`evidenceBacked`.
- `SchedulerService` (LLM) stays; its `ModelBenchmarkEvidence` becomes one adapter source so LLM and media
  selection share the same evidence vocabulary.

## 6. Phased implementation (so it is not a big-bang rewrite)
1. **This slice (now)**: land `CapabilityPerformanceEvidence` + adapters + `CapabilityEvidenceIndex` read
   accessor over the existing stores, with tests. No selection behavior changes yet. ← Stage 4.2a
2. Capability-aware ranking rule + `CapabilityScheduler`, unit-tested against recorded evidence. ← 4.2b
3. Wire it into `/v1/execute` Auto (evidence-backed model/resolution choice) + surface in the plan/web
   inspector. ← 4.2c
4. Backfill: have each runner persist `CapabilityPerformanceEvidence` after live runs so the index grows.

## 7. Non-goals (Stage 4.2)
- No global scoring rewrite; no new heavy models; no quality-score invention (reliability = validity rate).
- No change to `image.*`/`video.*`/`audio.*` provider contracts.
