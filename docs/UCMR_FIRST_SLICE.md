# esh 2.1 UCMR — Recommended First Implementation Slice + Reference Providers

**Not yet approved for implementation.** This proposes the smallest slice that proves the whole architecture end-to-end, plus the concrete first reference providers. See `UCMR_ARCHITECTURE.md` for the contracts and `UCMR_RESEARCH_AND_PRIORITIZATION.md` for the evidence.

## Why this slice
The release gate (spec §Release Gate) needs: additive core contract, **≥2 substantially different non-text providers**, typed artifacts end-to-end, scheduler capability-resolution, generalized Model Fit/catalog, typed Web/API, a security model, and "add a new provider without core surgery." The cheapest way to satisfy most of that — **without downloading heavy models, touching diffusion, or hitting license traps** — is:

**Stage 0 (core, no models) + Stage 1 (two zero-dependency providers): Embeddings/Reranking and Text→SVG.**

Both avoid new runtimes/deps (embeddings/rerank ride the **already-bundled `llama-server`**; SVG rides the **existing GGUF constrained-decoding** path + a deterministic Swift renderer). They are genuinely different output shapes (retrieval vector/ranked list vs. a validated file artifact with preview), so together they exercise every core seam.

## Stage 0 — core additive contract (no new models)
Build only the modality-generic plumbing, with adapters that keep 2.0 behavior byte-identical:
- `ExecutionRequest` / `ExecutionResult` / `CapabilityInput` / `OutputSpec` (+ `ExternalInferenceRequest`⇄`ExecutionRequest` adapter).
- `CapabilityProvider` protocol + `CapabilityRegistry`; wrap existing backends as `language.*` providers (no backend rewrite).
- `ExecutionPlan` (embeds today's `SchedulerDecision`/`ExecutionProfile`).
- `Artifact` + `FileArtifactStore` under a new `PersistenceRoot.artifactsURL`; optional typed-output link on `Message` (additive).
- `POST /v1/execute` + `GET /v1/artifacts/{id}` (reusing `binaryResponse`/`bodyStream`); additive `EshStreamEvent` cases (`status`/`progress`/`artifactProduced`/`previewReady`).
- **All v2.0 routes and types untouched.**

## Reference provider 1 — Embeddings + Reranking (zero new runtime)
- **Capabilities:** `language.embed`, `language.rerank`.
- **Runtime:** the bundled static `llama-server` (MIT) with `--embeddings` / `--reranking`; a second server instance managed by the existing `LlamaServerProcess`/`RuntimeLifecycleManager` (embedding models are tiny; residency is cheap).
- **Models (catalog additions):** `EmbeddingGemma-300M` or `Qwen3-Embedding-0.6B` (embed) + `bge-reranker-v2-m3` (rerank). All GGUF, permissive.
- **Output:** typed non-text — `ExecutionResult` with an `embedding`/`ranked` output (not an artifact file; structured JSON). Proves the result type isn't text.
- **Fit/evidence:** capability-specific metrics — `ms/embedding`, `dim`; `ms/query`, ndcg — not tok/s.
- **API:** exposed via `/v1/execute` **and** the OpenAI-compatible `/v1/embeddings` (additive standard route) so external clients/Ashex benefit immediately.
- **Proves:** capability-keyed dispatch, non-text typed output, catalog generalization, non-tok/s fit metrics — with **no new dependency and no GPL** (avoid `mlx-embeddings`).

## Reference provider 2 — Text → SVG (zero new model download)
- **Capability:** `vector.generate`.
- **Pipeline:** prompt → an installed **coding/structured LLM** emits a constrained **JSON scene-IR** (via the existing GGUF JSON-schema→GBNF constrained decoding — already supported for `.gguf`) → a **deterministic Swift renderer** compiles the IR to guaranteed-valid, whitelist-only SVG → validator (libxml2/`XMLParser`: well-formed, root `<svg>`, no `<script>/<foreignObject>/<use>`/remote refs/SMIL/`on*`, bounded dims, re-serialize-verify).
- **Output:** an `Artifact{kind:.svg, mimeType:"image/svg+xml", files:[…], metadata:{width,height}, validation, preview:.staticSandbox}` persisted in the artifact store and linked to the message.
- **Preview:** **artifact-only / secure-static** — rendered via WKWebView `<img>` mode (scripts never run, no external fetch). Default least-privilege; no execution.
- **Proves:** typed **Artifact** end-to-end, blob storage + session linkage, `/v1/artifacts/{id}` transport, **assistant-side typed rendering in Web**, and the tier-1 safe-preview path — the spec's explicit extensibility acceptance test (Extension A).
- **Implementation independence:** the capability contract does not depend on this method — a future specialized vector model or image→vector (vtracer, MIT) provider can replace/augment it without contract change.

## What this slice deliberately excludes (later, benchmark-gated)
Vision/VLM (needs the MLX-bridge image entry point), OCR, background removal (new Python/ONNX dep), image generation (mflux/diffusion), video, audio-gen, and runnable Node/Next.js preview (tier-4 isolation). These are Stage 2–4 in the sequence doc, each added as a provider + metadata + benchmark profile + (optional) preview adapter — **no core surgery**, which is the point of Stage 0.

## Release-gate coverage after Stage 0+1
| Gate item | Covered by Stage 0+1? |
|---|---|
| additive core contract exists | ✅ Stage 0 |
| ≥2 substantially different non-text providers | ✅ embeddings/rerank + SVG |
| typed artifacts end-to-end | ✅ SVG artifact + store + `/v1/artifacts` |
| scheduler capability-resolves them | ✅ capability-keyed candidates |
| Model Fit/catalog generalized | ✅ non-LLM catalog entries + non-tok/s metrics |
| Web/API consume typed outputs | ✅ `/v1/execute`, assistant typed rendering, `/v1/embeddings` |
| security model for runnable artifacts | ✅ privilege levels defined; SVG uses tier-1 (runnable-project tiers designed, deferred to Stage 4) |
| new provider without core surgery | ✅ demonstrated by adding #2 after #1 |
| tests for unsupported/mixed modalities + failures | ✅ part of Stage 0/1 test plan |
| 2.0 text/speech compatibility | ✅ adapters; routes unchanged |

Everything except the *runnable-project* security tier (tier-4) is provable at Stage 0+1; tier-4 lands with Stage 4 (managed preview) per the sequence doc.

## Open decisions for the user
1. **Approve the architecture** in `UCMR_ARCHITECTURE.md` (contract, provider registry, ExecutionPlan, Artifact, storage/transport, security tiers) — or request changes.
2. **Approve the sequence revision** (Stage 0/1 architecture proof — embeddings + SVG — *before* vision), or keep vision-first per the original Phase-14 hypothesis.
3. Confirm naming (`ExecutionRequest`/`CapabilityProvider`/`Artifact` vs. house alternatives) before any code.

Then implementation proceeds incrementally, one stage at a time, each behind tests + (for models) benchmark gates, preserving the 2.0 baseline.
