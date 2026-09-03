# esh 2.1 — Universal Capability & Modality Runtime (Architecture)

**Source of truth:** ClickUp `86eyu95qm`. **Status:** architecture + research phase — *no implementation until approved.*
**Companion docs:** `UCMR_RESEARCH_AND_PRIORITIZATION.md` (ecosystem + sequence), `UCMR_FIRST_SLICE.md` (reference providers + gate mapping).

North Star: a caller asks for an **outcome** —
`inputs + capability + desiredOutput + constraints → ExecutionPlan → typed result` —
without naming a model or runtime. esh owns the local execution details. This is an **additive** milestone: every 2.0 contract and behavior is preserved; text/STT/TTS become capabilities in the same architecture rather than parallel special-cases.

---

## 1. Repository truth (audit map — code over docs)

Audited the live tree (Swift 6 / SwiftPM; `EshCore` library + `esh` executable; Python bridge `Tools/mlx_vlm_bridge.py`). The single most important finding:

> **The input + capability *data* layers already exist and are modality-complete — but dormant. The gaps are consistently on the *output* side (typed results/artifacts, their storage, transport, rendering) and in *wiring* the existing modality data into the scheduler/catalog/fit consumers. Only two places bake text in deeply.**

### 1.1 What already exists and is modality-agnostic (reuse as-is)
- **Typed multimodal input contract.** `EshAttachment` (`Sources/EshCore/Domain/InferenceContractV2.swift:55`) — `Kind{image,document,audio,other}`, `mimeType`, `uri` **or** `base64`, `name`. Carried on `ExternalInferenceRequest.attachments` (`Sources/EshCore/Domain/ExternalCommand.swift:247`).
- **Modality-complete model metadata.** `ModelTask` (text/audio/vision/embedding/reranker/tool/multimodal) and `ModelModality` (text/audio/image/video/embedding/json/toolCall) — `Sources/EshCore/Domain/ModelCapabilities.swift:3,13`; `ModelCapabilities` with audio/vision/embedding/reranker/tool sub-structs (`:23`); the **open** `ModelCapabilityFilter` already enumerates `tts,stt,sts,timestamps,image-understanding,ocr,embedding,rerank,tool-calling,json-planning` (`:210`). All carried on **every** `ModelSpec` (`Sources/EshCore/Domain/ModelSpec.swift:13-16`).
- **A dead-but-present multimodal seam.** `BackendRuntimeFeature.multimodalInput` is declared and **never produced or consumed** (`Sources/EshCore/Domain/BackendCapabilities.swift:10`) — a ready hook.
- **Modality-neutral lifecycle/ownership.** `RuntimeLifecycleManager` (`Sources/EshCore/Runtime/RuntimeLifecycleManager.swift:8`) traffics in opaque `BackendRuntime`+`ModelInstall`; residency/eviction/budget and the new `setExternalReservation` (M12) are text-free. STT already shares the pool's budget through it — proof the pool can own non-text runtimes.
- **A decision envelope that is 80% of an ExecutionPlan.** `SchedulerDecision` (`Sources/EshCore/Domain/CapabilityRequest.swift:55`) carries `selectedModelID`, `backend`, `performanceMode`, `executionProfile`, fit/memory, `rationale[]` — no field is text-specific. `ExecutionProfile` (`Sources/EshCore/Optimization/ExecutionProfile.swift:7`) is a data-driven "which strategies + why" container.
- **Binary transport already exists** (`OpenAICompatibleHTTPHandler.binaryResponse`, used only by `/v1/audio/speech`), plus the generic `WebDataRequest` passthrough and SSE `bodyStream`.
- **The honest-resolution mechanism** (`CapabilityResolver.Outcome`/`ResolvedOption`/`CapabilityResolution`) is modality-neutral — the natural place to record "audio input accepted/rejected."

### 1.2 Where text is baked in deeply (the real work)
- **The runtime I/O signature.** `BackendRuntime.generate(session: ChatSession, config:) -> AsyncThrowingStream<String, Error>` (`Sources/EshCore/Protocols/BackendRuntime.swift:157`). Chat-in, `String`-out. All four backends produce `String` streams.
- **Format-keyed dispatch.** `InferenceBackendRegistry.backend(for:)` switches on `install.spec.backend` (`BackendKind` mlx/gguf/onnx/apple) (`Sources/EshCore/Services/InferenceBackendRegistry.swift:18`) — on model **format**, never on requested **capability**.
- **Text-only result.** `ExternalInferenceResponse.outputText: String` (non-optional) (`ExternalCommand.swift:320`), assembled by `outputText += chunk` (`Sources/EshCore/Services/ExternalInferenceService.swift:245`). No `outputs[]`/artifacts. The one artifact type (`OpenAIAudioSpeechResponse.audioData: Data`) is outside the contract and not `Codable`.
- **Text-only session/message.** `Message` is `id/role/text/createdAt` (`Sources/EshCore/Domain/Message.swift:3`) — no attachment/content-part field; generated media has no persisted home or session linkage.
- **Text-only transports downstream.** `mlx_vlm_bridge.py` uses `mlx_lm` for load/generate and imports `mlx_vlm` **only** for TurboQuant KV-cache — **no image entry point** (`Tools/mlx_vlm_bridge.py:64-84,489-518`). `llama-server` launched **without `--mmproj`** (`Sources/EshCore/Backends/GGUF/LlamaServerProcess.swift:40`). Despite the filename, VLM is not wired.

### 1.3 Speech is a fully parallel stack (to be folded in, not rewritten)
STT (`SpeechToTextService`, `SpeechRuntimeManager`, `SpeechWorkerProcess`) and TTS (`AudioSpeechGenerator` via external `TTSMLX`) live **outside** `InferenceBackend`/`BackendRuntime`/registry; they reach the API only as injected closures on `OpenAICompatibleService` (`:802-828`). The code itself flags the intended fix: *"a future SpeechBackend-style abstraction (M21) can unify both under the warm pool"* (`SpeechRuntimeManager.swift:8-9`). **This milestone supersedes the standalone SpeechBackend seam:** the general `CapabilityProvider` below subsumes it.

### 1.4 Honesty gap found (fix regardless)
The "attachments are never silently dropped" guarantee holds only for the *native* `ExternalInferenceRequest.attachments` path (it emits a visible `.rejected` `ResolvedOption`). The **OpenAI/Anthropic HTTP adapters and Web Chat silently drop `image_url` content parts** (`OpenAICompatibleService.swift:230`, `WebChatPage.swift:1278`). When we consume attachments, close this too.

### 1.5 Summary table

| Layer | State today | Action |
|---|---|---|
| Input contract (`EshAttachment`) | exists, unconsumed | **wire through** (consume, don't invent) |
| Model capability metadata | exists, ignored by consumers | **wire into** scheduler/catalog/fit |
| `BackendRuntimeFeature.multimodalInput` | declared, unused | **activate + extend** vocabulary |
| Lifecycle/warm pool | modality-neutral | **unchanged** |
| `SchedulerDecision`/`ExecutionProfile` | neutral envelopes | **promote to `ExecutionPlan`** (additive) |
| Runtime I/O (`generate→String`) | text-baked | **generalize** to typed events (deepest change) |
| Registry dispatch | format-keyed | **add capability-keyed** resolution |
| Result (`outputText: String`) | text-only | **add `outputs: [Artifact]`** (additive) |
| `Message`/session | text-only | **add typed output/attachment** (additive) |
| Artifact storage | none (only prompt-cache) | **add blob artifact store** |
| Transport | JSON + audio-only binary | **add `/v1/execute` + artifact-by-reference** |
| Web rendering | assistant = markdown only | **typed-result renderers** (reuse user-side) |
| Speech | parallel stack | **fold into provider registry + pool** |

---

## 2. Universal Capability Contract (additive)

New canonical request, additive to Inference Contract v2. The existing `ExternalInferenceRequest` remains valid and becomes the *text-generation specialization* (adapted into an `ExecutionRequest` internally), so 2.0 callers are untouched.

```swift
public struct ExecutionRequest: Codable, Sendable {
    public static let schemaVersion = "esh.execute.request.v1"
    public var schemaVersion: String
    public var capability: CapabilityID          // what to do (family.verb)
    public var inputs: [CapabilityInput]         // typed, multiple, mixed modality
    public var output: OutputSpec                // desired typed output + format
    public var constraints: ExecutionConstraints // privacy/latency/quality/memory/localOnly
    public var options: ExecutionOptions         // capability-specific knobs (freeform, typed per family)
}
```

- **Multiple/mixed inputs are first-class** (`text + image`, `video + question`, `document + instruction`). Inputs reuse and extend the existing `EshAttachment` payload rather than inventing a parallel type.
- **The output is declared, not assumed text.** `OutputSpec` carries a modality/type + optional format (e.g. `svg`, `png`, `json+schema`, `embedding`, `ranked`, `project`).
- `ExecutionConstraints` generalizes today's `CapabilityRequest` flags (quality/latency/localOnly) and adds memory/time budgets and a **max privilege level** (see §9).

**Compatibility:** `ExternalInferenceRequest` → `ExecutionRequest` is a lossless adapter (`capability = language.generate`, inputs from messages+attachments, output = text/json per `EshResponseFormat`). The reverse adapter lets the text path keep returning `ExternalInferenceResponse` verbatim.

---

## 3. Modality / Input / Output type system

Reuse the **already-present** `ModelModality` vocabulary; extend additively.

```swift
public struct CapabilityInput: Codable, Sendable {
    public enum Payload { case text(String); case attachment(EshAttachment); case structured(JSONValue); case embedding([Float]) }
    public var payload: Payload
    public var role: String?        // optional semantic role: "prompt","instruction","reference","question"
}
```

Typed outputs are represented as **Artifacts** (§5) plus optional inline text. Output kinds (additive to `ModelModality`): `text, structuredJSON, image, svgVector, audio, video, document, code, projectBundle, embedding, ranked, segmentation`. **Rule (from spec):** binary/media results are never forced into JSON strings/base64 — they are Artifacts referenced by id and fetched as bytes (§10).

`EshAttachment.Kind` extends additively: `+ video, + structured, + code` (today: image/document/audio/other).

---

## 4. CapabilityProvider architecture

A single protocol that **subsumes `BackendRuntime` and the speech special-cases**, dispatched on **capability**, not format.

```swift
public protocol CapabilityProvider: Sendable {
    // Declarative metadata (advertised to the registry + scheduler + Model Fit)
    var descriptor: CapabilityProviderDescriptor { get }
    // Execute; the event stream is typed (text delta, artifact, progress, …), not String-only
    func execute(_ request: ResolvedExecutionRequest,
                 context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error>
    func unload() async
}

public struct CapabilityProviderDescriptor: Sendable {
    public var capabilities: [CapabilityID]           // e.g. [language.generate, language.embed]
    public var acceptedInputs: [ModelModality]
    public var producedOutputs: [ModelModality]
    public var backend: RuntimeKind                   // mlx | gguf | apple | appleVision | python | native
    public var modelFamily: String?
    public var streaming: Bool
    public var structuredOutput: Bool
    public var resources: ResourceRequirements        // memory/disk/runtime deps
    public var fit: ModelFitProfile?                  // capability-specific fit metadata
    public var preview: PreviewCapability?            // none | staticSandbox | managed
    public var security: SecurityRequirements         // privilege level needed
}
```

- **`BackendRuntime` is retained** as the LLM provider; a thin adapter exposes each existing backend as a `CapabilityProvider` for `language.*`. No backend rewrite.
- **Speech becomes two providers** (`audio.transcribe`, `audio.synthesizeSpeech`) that the `RuntimeLifecycleManager` owns via the same `acquire`/`withRuntime` path — replacing the bespoke `SpeechRuntimeManager` actor and injected closures over time (2.0 audio routes stay byte-compatible).
- **`CapabilityID` is data, not a closed enum** (mirrors the "strategies are data" pattern in `OptimizationTypes`). Well-known constants map onto the existing `ModelCapabilityFilter` values so nothing is duplicated.
- **`RuntimeKind`** is a new axis (adds `appleVision`, `python`, `native`) so a provider can be a Core ML/Apple-Vision path or a Python-bridge path without abusing `BackendKind`. `BackendKind` stays for model *format*.

Resolution flow (spec §3): `ExecutionRequest → CapabilityRegistry (filter by capability × input modalities × output) → candidate providers → Scheduler/Planner → ExecutionPlan → provider(s) → typed result`.

```swift
public struct CapabilityRegistry {
    func providers(for capability: CapabilityID,
                   inputs: [ModelModality], output: ModelModality) -> [CapabilityProvider]
}
```
The existing format-keyed `InferenceBackendRegistry` becomes **one contributor** to this registry (the LLM/text providers). Adding a new capability = register a provider + metadata + catalog entry + (optional) benchmark profile + (optional) preview adapter — **no core surgery**, satisfying the acceptance gate.

---

## 5. First-class Artifact

```swift
public struct Artifact: Codable, Sendable {
    public var id: UUID
    public var kind: ArtifactKind            // image | svg | audio | video | document | code | webProject | embedding | ranked | segmentation
    public var mimeType: String
    public var files: [ArtifactFile]         // {relativePath, byteSize, sha256}
    public var entrypoint: String?           // for multi-file/projects
    public var metadata: [String: JSONValue] // dimensions, duration, dims, etc.
    public var generatedBy: ArtifactProvenance   // provider, model, ExecutionPlan id
    public var validation: ArtifactValidation    // valid/invalid + findings (e.g. SVG sanitize report)
    public var preview: PreviewDescriptor?       // how it can be previewed + required privilege
}

public struct ProjectArtifact: Codable, Sendable {  // specialization for runnable web projects
    public var artifact: Artifact
    public var framework: ProjectFramework   // staticWeb | threejs | nextjs | other
    public var packageManifest: String?
    public var runtimeRequirements: RuntimeRequirements   // node version, network-needed-for-install
    public var previewConfiguration: PreviewConfiguration
}
```

Artifacts are the typed result carrier. They persist in a new blob store (§10) and link to the originating session/message. `ExecutionResult.outputs: [Artifact]` sits **alongside** the retained `text` channel — never replacing it.

---

## 6. ExecutionPlan integration

Promote the implicit `SchedulerDecision`+`ExecutionProfile` pair into a first-class, capability-typed **`ExecutionPlan`** (additive — the existing types remain and are embedded/adapted).

```swift
public struct ExecutionPlan: Codable, Sendable {
    public var capability: CapabilityID
    public var inputModalities: [ModelModality]
    public var outputModality: ModelModality
    public var steps: [ExecutionStep]        // 1 step = single provider; N = multimodal pipeline (§ spec 10)
    public var rationale: [String]           // "Why this execution plan?" — truthful, per spec §11
    public var evidenceBacked: Bool
    public var estimatedPeakMemoryGB: Double?
    public var privilegeLevel: PrivilegeLevel
}
public struct ExecutionStep: Codable, Sendable {
    public var providerID: String
    public var modelID: String?
    public var backend: RuntimeKind
    public var profile: ExecutionProfile?    // reuse existing optimization profile per step
    public var consumesOutputOf: Int?        // pipeline wiring
}
```

Single-provider calls are a 1-step plan; **multimodal pipelines** (video→keyframes→VLM + audio→STT → reasoning; image→vectorize→SVG→validate) are N-step plans, observable and evidence-gated. This is a superset of today's decision object — the text path keeps producing the same rationale.

---

## 7. Scheduler v2 integration

`SchedulerService.decide` becomes capability/modality-aware by **consuming data it already ignores**:
- Extend `CapabilityRequest` with a `capability`/modality axis (today: `Goal{general,coding,reasoning,structured}` only — `CapabilityRequest.swift:6`).
- Filter candidates by `install.spec.capabilities` / `inputModalities` / `outputModalities` (today discarded) via `ModelCapabilityFilter`, replacing the closed `RecommendedModel.Capability` derivation (`SchedulerService.swift:207-256`).
- Rank with **capability-specific** evidence (not just tok/s) — see §9.
- Emit an `ExecutionPlan` with truthful rationale (spec §11 example: image background-removal picks the larger, better-edge model when headroom allows, and says why).

`CapabilityResolver` gains data-driven backend facts and audio/multimodal branches (today it hard-codes `supportsNativeConstrainedDecoding == .gguf` and blanket-rejects attachments/tools/vision).

---

## 8. Model catalog evolution

- The **served** catalog (`RecommendedModelRegistry.defaultModels`, 26 LLM entries; LLM-only `Capability{chat,coding,reasoning,toolCalling,vision}`) must source capabilities from the already-general `ModelCapabilities` on `ModelSpec`, and gain non-LLM entries (VLM, embedding, reranker, OCR, image-gen, segmentation).
- `WebCatalogModel.capabilities` (fed from the LLM enum, `WebExperienceData.swift:120`) surfaces the rich capability set instead.
- Install/fit/compat flow already delegates to `ModelSpec`; only the recommendation/filter surface needs generalizing.

---

## 9. Model Fit evolution (capability-specific metrics)

- `ModelFitService` stays first-class for every modality; the **estimator** is parameterized by modality instead of "params × bits × token-context" only (`ModelFitService.swift:82-109`). Add footprint models for diffusion (latent + UNet/transformer + VAE), VLM (vision encoder + LLM), audio (sample-rate/duration), embedding (small).
- Wire the already-modeled-but-unset `ttsReserveGB`/`speculativeDraftGB` from the scheduler (currently 0 in the scheduling path).
- **Benchmark metric taxonomy by modality** (extend `BenchmarkPerformance`/`BenchmarkMetrics`, both tok/s-only today):
  - image-gen: load, **sec/image**, peak mem, resolution, quality
  - video-gen: **sec/frame** / total, peak mem, max duration/resolution
  - STT: **realtime factor**, WER (when measured)
  - embeddings: **ms/embedding**, dim; rerank: **ms/query**, ndcg
  - artifact/code: **validity/build rate**, test/pass rate, latency
  - **Never force everything into tok/s.** Evidence keyed by `(modelID, capability, hardware class, workload)`.

---

## 10. Binary/media streaming + artifact storage

- **Storage:** add `artifactsURL` as a sibling of `audioURL`/`tempURL` under `PersistenceRoot` (assets root, relocatable/external-volume aware). Artifacts persist as `{manifest.json + files}`; a new `FileArtifactStore` + `ArtifactManifestIO` (the prompt-cache `CacheArtifact` is unrelated and stays as-is). `Message` gains an optional typed-output/attachment reference so results link to the conversation.
- **Transport:** binary/media results are served **by reference**, not base64 in JSON:
  - `POST /v1/execute` returns an `ExecutionResult` JSON with `outputs:[{artifactId, kind, mimeType, previewURL}]`.
  - `GET /v1/artifacts/{id}` (and `/{id}/{file}`) streams bytes via the existing `binaryResponse`/`bodyStream` primitives.
  - SSE streaming (`EshStreamEvent`, already extensible) gains additive events: `status`, `progress`, `artifactProduced(id)`, `previewReady(url)`, plus typed `audioDelta`/`imageDelta` where a provider streams media. The internal `MLXWorkerEvent` shows the typed-event pattern already exists one layer down.
- Existing OpenAI/Anthropic/Ollama routes and the audio-speech binary path stay byte-compatible.

---

## 11. Safe preview / execution security model (threat model)

**Privilege levels (default = least privilege that satisfies the request):**

1. **artifact-only** *(default for text→SVG, JSON-IR→SVG)* — no execution, no network, no JS. SVG rendered in WKWebView **secure-static (`<img>`) mode** (scripts never run, no external fetch — structural guarantee).
2. **validated** — sanitized static HTML/CSS/SVG in WKWebView with **JS off** (`allowsContentJavaScript=false`), network blocked.
3. **preview-sandboxed** — self-contained interactive HTML/JS (e.g. Three.js single file), **JS on** but strict CSP `default-src 'none'` **injected by us via a custom `esh-artifact://` scheme handler (never trusting the artifact's own `<head>`)** + `WKContentRuleList` block-all + no real origin. Ceiling for "static-but-interactive"; safe after tiers 1–2.
4. **explicit-full** *(opt-in, per-project, never default)* — runnable Node/Next.js. **Preferred isolation: Apple `container`/Containerization.framework (macOS 26, VM-per-container)**; fallback: **`sandbox-exec`/Seatbelt + POSIX rlimits** (deprecated-but-functional, no removal date — wrap behind an isolation abstraction so it can be swapped). Loopback-only + random port, `npm ci` + `.npmrc ignore-scripts=true` + npm-12 defaults, dependency-provenance UX, clean process-group/VM teardown.

**Threat → mitigation (summary):** shell exec/fs read/network exfil → VM or Seatbelt scoping + deny-network-default; malicious npm postinstall → `ignore-scripts`+`npm ci`+lockfile; **import-time npm malware → execution isolation + no-network (install flags are insufficient — stated honestly)**; runaway process → rlimits + wall-clock + kill group; localhost LAN exposure → bind 127.0.0.1 + enforce at net layer; SVG/HTML XSS/mXSS → sanitize + re-parse-verify + secure-static; XXE/entity-expansion → disable external entities/DTD in libxml2/`XMLParser`.

**SVG safety pipeline:** prefer **constrained JSON "scene IR" → deterministic Swift renderer** (only whitelisted elements are ever emitted — eliminates sanitization at the source) over free-form SVG grammar. For image→SVG use **vtracer (MIT)** (avoid potrace/autotrace — GPL). Validate all SVG: well-formed XML, root `<svg>`, strip `<script>/<foreignObject>/<use>/<image>`-remote/SMIL/`on*`/external refs, bound dimensions, re-serialize-and-verify.

**Never auto-run generated code.** Execution/preview is always explicit and user-triggered.

---

## 12. Web / API integration

- **API:** additive `POST /v1/execute` (capability request) + `GET /v1/artifacts/{id}`; **all v2.0 OpenAI/Anthropic/Ollama routes unchanged** (`2_0_API_SEMVER_CONTRACT.md` honored). Compatibility routes keep adapting text/chat use-cases independently.
- **Web UX stays minimal.** Normal user just types (`"Create an SVG logo of a fox"`) or attaches (`+ Image`, `"remove the background"`). The web renders **typed results** by reusing the existing user-side renderers (image `<img>`, `audioPlayer`/`wireAudioPlayers`, attachment pills) — now on the **assistant** side too — plus a **Preview** action and file download/export. The Execution Inspector (advanced) shows provider/model/runtime/`ExecutionPlan`. Modality implementation detail stays hidden by default.

---

## 15. Migration / additive-compatibility assessment

- **No breaking changes.** Every new type is additive; `ExternalInferenceRequest`/`Response`, `Message`, all v2.0 routes, and the audio-speech binary path keep working. New fields are optional with backward-compatible decode (the codebase already does this for `ModelSpec` modality fields).
- **Text/STT/TTS behavior preserved**: the text path is an `ExecutionRequest(language.generate)` adapter; speech routes keep byte-compatible responses while their implementation migrates behind a provider.
- **2.1 RC gate reused:** every RC re-runs the packaged/notarized + no-Homebrew validation and the 2.0 compatibility suite.
- **Sequencing:** land the *core additive contract + registry + ExecutionPlan + artifact store + `/v1/execute`* first (no new models), then add providers one at a time behind benchmark gates. See `UCMR_FIRST_SLICE.md`.

---

## Acceptance-gate mapping (spec §16 A–H)

For each future extension, "most of the work lives in provider/adapter + capability metadata + optional benchmark profile + optional preview adapter" — **no core surgery** — because §2–§12 make inputs, dispatch, results, storage, transport, and rendering modality-generic:

| Ext | Capability | Provider work | Core work (should be ~0) |
|---|---|---|---|
| A `text→SVG` | `vector.generate` | JSON-IR provider + Swift SVG renderer + validator | none (contract/artifact/preview exist) |
| B `text→image` | `image.generate` | mflux provider (Z-Image/FLUX schnell) | none |
| C `image+text→edit` | `image.edit`/`image.segment` | rembg/segmentation or diffusion-edit provider | none (multi-input already legal) |
| D `audio→understanding` | `audio.understand`/`diarize` | pyannote provider | none |
| E `video+text→answer` | `video.understand` | pipeline plan (keyframes→VLM + STT→reason) | none (N-step ExecutionPlan) |
| F `text→static web artifact` | `webArtifact.generate` | code provider + validator + tier-3 preview | none |
| G `text→Three.js project` | `project.generate` | code provider + ProjectArtifact + preview adapter | preview runtime (tier-3/4) |
| H `text→Next.js project` | `project.generate` | code provider + managed preview (Apple container) | isolation runtime (tier-4) |
