# esh 2.1 UCMR — Managed Project Runtime / ProjectArtifact v2 (Design Spec — DESIGN ONLY)

**Status:** ✅ **ARCHITECTURE APPROVED (2026-09-04).** Implementation may proceed per the phased plan (§9); first managed tier = Tier B (Three.js / browser-module). Tier C (Node) remains a separate future milestone gated on a proven macOS OS-sandbox; Tier D stays Ashex.
**Author context:** follows `project.generate` (static ProjectArtifact) reaching PRODUCTION-READY.
**Scope boundary:** esh generates + validates + previews artifacts locally & privately. Autonomous repo/editing/deploy stays in **Ashex**.

This document is grounded in the current codebase (file:line references are to `…/MLX+TurboQuant/Source`). Where it says *exists*, the primitive is already in the tree; where it says *add*, it is new work.

---

## 0. Problem statement

Today:

```
text → project.generate → static ProjectArtifact (html/css/js) → isolated iframe preview
```

We want to reach, without the caller choosing a model/framework/runtime:

```
text → richer ProjectArtifact → validate → isolated managed runtime → interactive preview
```

Target requests: *"interactive 3D Earth with earthquake markers"*, *"a small dashboard for these metrics"*, *"a Three.js solar system"*.

The hard part is **not** generation — it is **executing generated code safely**. The design must make the security boundary explicit and refuse to pretend an unsupported/unsafe tier exists.

---

## 1. Project runtime tiers (explicit capability progression)

| Tier | What | Runtime | Deps | Network at run | Status |
|---|---|---|---|---|---|
| **A — Static ProjectArtifact** | html/css/js + local assets | browser (iframe) | none | none | **PRODUCTION** (`project.generate`) |
| **B — Browser-native managed** | + Three.js / WebGL / Canvas / SVG / ES modules via **import-map + esh-vendored libs** | browser (iframe), esh serves pinned local libs | **esh-controlled allowlist only** (no npm at runtime) | none (all deps local) | **proposed first managed tier** |
| **C — Managed framework** | React / Vite / Next.js | Node dev/build server in a sandbox | package install + resolver | build-time only, then none | **future** (separate phase; do NOT bundle with B) |
| **D — Agentic project dev** | edit user repo, run shell, deploy, iterate | full host | arbitrary | arbitrary | **Ashex, not esh** |

Key decision: **Tier B needs no Node.** Three.js ships an ES-module build that runs directly in the browser via an import map. So Tier B extends the *existing* static pipeline (generate → validate → iframe) with (1) an esh-vendored, pinned dependency set served from the artifact/loopback origin and (2) richer validation — **not** a Node runtime. That keeps the whole managed-runtime story inside the browser sandbox we already trust, and defers the genuinely dangerous part (arbitrary package execution + Node) to Tier C behind a real OS sandbox.

---

## 2. ProjectArtifact v2 schema

### 2.1 What exists (`Sources/EshCore/Domain/Artifact.swift`)
`Artifact{ id, kind, mimeType, files[ArtifactFile], entrypoint, metadata[String:JSONValue], generatedBy(ArtifactProvenance), validation(ArtifactValidation), preview(PreviewDescriptor), createdAt }`. `PreviewDescriptor.Mode` already declares `.staticSandbox` **and `.managed`** (the latter reserved-but-unused). `PrivilegeLevel` declares `.previewSandboxed` **and `.explicitFull`** (also unused). `ArtifactKind` has `.webProject` (currently overloaded for single-file *and* multi-file).

### 2.2 Design principle
**Do not make framework names fundamental.** The runtime should key off a generic *runtime-requirement* abstraction, not `if projectType == .nextjs`. `projectType` stays a coarse descriptive label; execution is driven by `runtimeRequirements` + `dependencies` + `permissions`.

### 2.3 Proposed additions (additive, backward-compatible — mirrors how v1 layered onto the contract)
Extend `Artifact.metadata` via a typed, Codable side-struct persisted in `metadata["project"]` (no breaking change to `Artifact`), OR promote to first-class fields in a v2 manifest. Recommended shape:

```
ProjectArtifact (conceptual)
  files: [ArtifactFile]                    // exists
  entrypoint: String                       // exists
  projectType: ProjectType                 // NEW — descriptive: static-web | threejs | browser-module | react | vite | nextjs | future
  runtimeRequirements: RuntimeRequirements // NEW — the abstraction execution keys off
      kind: .browserStatic | .browserModule | .nodeManaged   // generic, not framework
      importMap: [String:String]?          // module specifier → local vendored path (Tier B)
      needsBuild: Bool                     // Tier C
      needsServer: Bool                    // Tier C
  dependencies: [ResolvedDependency]       // NEW — name, version (pinned), integrity(sha256), source(vendored|registry), scope(browser|node)
  permissions: ProjectPermissions          // NEW — network:.none(default)|.loopback|.allowlist[hosts]; filesystem:.sandboxOnly; camera/mic/etc:.deny by default
  provenance: ArtifactProvenance           // exists (+ dependencyProvenance)
  validation: ProjectValidationReport      // extend existing stage report (see §7)
  sourceArtifacts: [UUID]                   // exists as provenance.sourceArtifactID → generalize to a list for multi-source
  previewConfiguration: PreviewConfig       // NEW — previewMode, privilege, sandboxFlags, csp, lifetime
```

`ProjectType` and `RuntimeRequirements.kind` are separate on purpose: two frameworks can share a runtime kind; a runtime kind can host several project types. Router/scheduler set `projectType`; the runtime only reads `runtimeRequirements` + `permissions`.

### 2.4 Kind
Introduce a dedicated `ArtifactKind.project` (or keep `.webProject` and disambiguate via `projectType`). Recommendation: **keep `.webProject`** for browser-previewable projects (Tiers A/B) to avoid churn in the serving/preview path; reserve a future `.managedProject` only if Tier C needs a different serving contract. Decision deferred to implementation, flagged here.

---

## 3. Sandbox design (what macOS actually enforces)

**Honesty rule:** claim only what a primitive actually enforces.

### 3.1 Tier B (browser-native) — the trust anchor is the iframe, not the OS
- Reuse the existing embed: `iframe sandbox="allow-scripts allow-pointer-lock"` **without `allow-same-origin`** → opaque origin, no parent/cookie/storage/top-nav access (`WebChatPage.swift:741-748`).
- **Add server-side headers** (currently ABSENT — `OpenAICompatibleHTTPHandler.swift:254-273` sets none): `Content-Security-Policy` (default-src 'self'; script-src 'self'; connect-src 'none' by default; img-src 'self' data:; object-src 'none'; base-uri 'none'), `X-Content-Type-Options: nosniff`, `X-Frame-Options`/`frame-ancestors` scoped to the esh origin. This makes isolation defense-in-depth rather than client-only.
- **Network at run = none by default.** `connect-src 'none'` blocks fetch/XHR/WebSocket from generated code; all deps are same-origin vendored files. A capability that legitimately needs remote data (e.g. live earthquake feed) requires an explicit `permissions.network = .allowlist[hosts]` → reflected into CSP `connect-src` — opt-in, surfaced to the user, never model-decided.
- WebGL availability is the browser's; no OS work needed. GPU is already sandboxed by the browser.

### 3.2 Tier C (Node) — real OS sandbox required (future)
What **exists** to build on: `ProcessRunner.runCancellable` (SIGTERM→2s→SIGKILL, process teardown, cooperative cancel — `ProcessRunner.swift:31-127`); the Python RAM-guard pattern (`_run_guarded_image_cli`: killable process **group** via `start_new_session=True` + `os.killpg`, RAM-floor poll-and-kill — `Tools/mlx_vlm_bridge.py:1122-1176`); loopback-child-server precedent (`LlamaServerProcess` bound `127.0.0.1` — `LlamaServerProcess.swift:42`).
What must be **added** (and cannot be claimed until proven): enforced **wall-clock timeout** (ProcessRunner has none today), **memory cap** (only a cooperative floor-check exists, not an enforced limit), **CPU/process-count limits**, **filesystem confinement** to a temp project dir (`sandbox-exec` profile / `posix_spawn` + restricted cwd; note `sandbox-exec` is deprecated but functional — verify), **network egress control** (macOS has no per-process firewall in userspace without a Network Extension; realistic options: run Node with `--no-experimental-fetch`/no network by policy, or a loopback-only proxy, or accept "network on during `npm install`, off during run" with the install step itself sandboxed + registry pinned). **Do NOT ship Tier C claiming network isolation until a concrete enforceable mechanism is validated on macOS.**

### 3.3 Secrets non-exposure (both tiers)
Sandbox/preview processes must never see `~/.ssh`, `~/.esh/config.toml`, model/config secrets, or the assets root beyond the single project dir. Tier B gets this free (opaque-origin iframe, esh serves only the artifact dir). Tier C must launch with a scrubbed environment (no `HF_*` tokens, no home) and cwd pinned to the temp project sandbox.

---

## 4. Dependency policy (critical)

**Generated code must never trigger unrestricted install.** No `npm install <whatever-the-model-invented>`.

### 4.1 Tier B — curated, vendored, pinned browser libraries
- esh ships a **curated registry** of known-good browser ES-module libraries with **pinned versions + integrity hashes**, stored offline under the assets tree (mirrors the existing pinned-model pattern: `REAL_ESRGAN_ONNX_REVISION` pin at `mlx_vlm_bridge.py:1181`; expected-asset paths in `RoutingOutcome.swift:60-70`).
  - e.g. `three` → version `r168` (or current), sha256-verified, served from `<assets>/caches/web-libs/three/<ver>/three.module.js`.
- Generation flow: model requests a library by name → **Dependency Resolver** checks the curated registry → if known/approved/compatible, esh injects an **import map** into `index.html` pointing at the vendored local file; if unknown → **reject with an explain/clarify** ("Three.js is available; library X is not in esh's approved set"). Never fetch arbitrary URLs.
- Network disabled during execution (CSP `connect-src 'none'`), so even a sneaked remote `import` fails closed.
- Integrity: verify sha256 of each vendored file at serve time (we already compute per-file sha256 in `FileArtifactStore.save` — `Artifact.swift:22-31`).

### 4.2 Tier C — future
Resolver + pinned lockfile + offline/preinstalled package cache + `HF_HUB_OFFLINE`-style offline enforcement (note: `HF_HUB_OFFLINE` is *not* set anywhere today — offline is currently a gap). Install runs once, sandboxed, network limited to a pinned registry mirror, then network off for run. Out of scope for first implementation.

### 4.3 Vendoring/acquisition
Curated libs are fetched **once, by esh maintainers/tooling** (not at generation time) into the offline cache, with recorded version + hash — the same "download once, verify, pin" discipline already used for models. A request never causes a live download.

---

## 5. Preview lifecycle

Target UX:
```
User: "Create an interactive Three.js Earth."
esh:  Generating… Validating… Starting isolated preview… [interactive preview]  Open · Download project · Inspect execution
```

- **Artifact is durable; preview is disposable.** The ProjectArtifact persists in `FileArtifactStore` (`<assets>/artifacts/<uuid>/`). Closing the preview must NOT delete the artifact.
- **Tier B lifecycle:** artifact saved → served via existing `/v1/artifacts/{id}/{file}` (`OpenAICompatibleHTTPHandler.swift:149-162`) with the new CSP/sandbox headers → embedded in the opaque-origin iframe. No separate process; "preview" is just the iframe. Emit the already-existing-but-inert **`.previewReady(url:)`** event (`ExecutionResult.swift:15`, currently dropped at `CapabilityExecutionService.swift:219`) to hand the Web UI the entry URL. Lifecycle = iframe mount/unmount; nothing to tear down.
- **Tier C lifecycle (future):** ephemeral loopback dev-server child process (pattern: `LlamaServerProcess`), tracked with a handle, wall-clock timeout, RAM guard, and guaranteed teardown (`runCancellable`), temp dir cleaned on close. `.previewReady(url:)` carries the loopback URL; closing the preview kills the child + deletes the temp dir but keeps the artifact.

---

## 6. Routing semantics

Current discriminator (`DeterministicIntentRouter.generationCapability`, `DeterministicIntentRouter.swift:103-117`): precedence **SVG → project(cues) → web(nouns) → image → vector-fallback**, gated by `genVerbs`. `projectCues` already includes `"multi-file","web project","static site"` and beats `webNouns`.

**v2 additions:**
- Add cue sets for the managed tier without becoming eager:
  - `threejs` / `browser-module` cues: `"three.js","threejs","webgl","3d scene","interactive 3d","particle","shader","globe","solar system","orbit","visualization"` → route to `project.generate` with `projectType=threejs` (Tier B) **only when the tier is actually supported**; otherwise fall through / clarify.
- **Capability vs project-type split:** keep ONE capability `project.generate`; carry the tier/projectType as a resolved parameter (so the router picks *what*, the provider/runtime handles *how*). Avoid inventing a separate capability per framework.
- **Ambiguity → clarify, never eager escalation** (reuse the shipped Router Auto `ambiguous`/`unresolved` split). "Make me a website" → clarify among **{simple static site, interactive web experience, framework project}** — but only offer tiers esh actually supports today (never present Tier C as available before it ships).
- **Never pretend an unsupported runtime tier exists.** If a request maps to Tier C before Tier C ships → `unsupported`/explain ("framework projects aren't supported yet; I can build an interactive browser project instead").

Layer separation (must hold):
```
Router Auto   → WHAT (capability + projectType/tier)
Scheduler     → WHICH model generates it   (evidence-based, per project.generate policy)
Project Runtime → EXECUTES the resulting artifact (tier-appropriate sandbox)
```

---

## 7. Validation for dynamic projects (progressive)

Static validation (v1 `ProjectValidator` + `ProjectConsistency`: path safety, placeholder, cross-file refs, asset hygiene, structure) is necessary but insufficient for executable projects. Add a **progressive, bounded** pipeline:

```
manifest validation            (exists — layer 1)
→ file/reference validation    (exists — layer 2 cross-file)
→ syntax validation            (ADD — JS/HTML parse check; e.g. lightweight JS parse, HTML well-formedness)
→ dependency validation        (ADD — every import resolves to an approved vendored lib; import map complete; no remote imports)
→ build validation             (Tier C only, future)
→ sandboxed runtime smoke      (ADD — load entry in a headless/offscreen check: no uncaught error on load, canvas/WebGL context acquired for threejs)
→ optional browser health check (ADD, optional — DOM present, no console errors within N ms)
```

- **Bounded repair only** (reuse the shipped pattern: generate + ≤2 repairs, accept only if issue set strictly shrinks, never an unbounded agent). Feed structured issues (missing/importable dep, syntax error, runtime console error) back once or twice; else save honestly-invalid.
- **Do NOT build a general autonomous debugging agent.** (That trends toward Ashex.)
- Runtime smoke for Tier B can run in the same sandboxed iframe/headless webview esh already trusts; capture `console.error`/uncaught exceptions via the existing console-reading capability.

---

## 8. Why Three.js / browser-module should be the first managed tier

**For:**
- Highly visual, demonstrably "executable artifact" — proves the milestone's value.
- **Runs entirely in the browser** — no Node, no package execution, no OS sandbox needed beyond the iframe we already trust. The dangerous part (arbitrary install + host code execution) is deferred.
- Naturally extends the *existing* static pipeline: generate → validate → `/v1/artifacts` serve → opaque-origin iframe. The only genuinely new subsystems are (a) the curated/pinned/vendored dependency set + import-map injection and (b) richer validation (dependency + runtime smoke) — both self-contained.
- Dependency policy is tractable: a small curated allowlist (start with `three`) with pinned version + integrity, served offline — mirrors the proven "pin + verify + offline cache" model discipline.
- Bridges toward Tier C: exercises the ProjectArtifact v2 schema (`runtimeRequirements`, `dependencies`, `permissions`, `previewConfiguration`) and progressive validation without the Node blast radius.

**Against / risks (surface honestly):**
- Model quality: local Apple-FM-class models may write mediocre Three.js; mitigate with strong system prompts + the curated import map (so at least deps resolve) + runtime smoke to fail bad output honestly.
- WebGL flakiness in headless smoke checks — keep the runtime smoke tolerant (context-acquired, no uncaught error) rather than pixel-asserting.
- Scope creep into arbitrary CDNs — resist; allowlist only.

**Verdict:** **Yes — Three.js / browser-module (Tier B) is the correct first managed tier.** It maximizes demonstrated capability while keeping execution inside the already-trusted browser sandbox and deferring Node/OS-sandbox complexity to a later, explicitly-separate Tier C.

---

## 9. Implementation phases (when approved — NOT now)

- **Phase 0 — ProjectArtifact v2 schema (additive).** Add `projectType`, `runtimeRequirements`, `dependencies`, `permissions`, `previewConfiguration` (as a typed struct in `metadata["project"]`, backward-compatible). Tests: round-trip, v1 artifacts still load.
- **Phase 1 — Server hardening (independent, ship anytime).** Add CSP + `nosniff` + frame-ancestors headers to artifact responses (`OpenAICompatibleHTTPHandler`), default `connect-src 'none'`. Wire the inert `.previewReady(url:)` event through `CapabilityExecutionService` + Web UI. Tests: headers present; sandbox still renders.
- **Phase 2 — Curated dependency registry + vendoring.** Offline `<assets>/caches/web-libs/`, pinned `three` + integrity, a `DependencyResolver` (name → vendored path or reject). Tooling to fetch/verify once. Tests: approved resolves, unknown rejected, integrity mismatch rejected.
- **Phase 3 — Tier-B provider path.** Extend `project.generate` for `projectType=threejs`: import-map injection, dependency validation, self-contained enforcement (no remote imports). Tests: import map complete, remote import rejected, cross-file consistency holds.
- **Phase 4 — Progressive validation + runtime smoke.** Syntax + dependency + sandboxed load smoke; bounded repair on runtime/dep errors. Tests: broken import → repaired; runtime console error → invalid.
- **Phase 5 — Routing + clarify.** threejs/browser-module cues; ambiguity clarify among supported tiers only; unsupported→explain. Tests: Tier-0 false-exec stays 0; "solar system" → threejs; "next.js app" → unsupported/explain.
- **Phase 6 — Web UX.** Managed preview embed, Open/Download/Inspect, `.previewReady` URL, disposable-preview semantics (artifact persists).
- **Phase 7 — Live proofs + docs + verdict.** ≥3 interactive projects (3D Earth+quakes, solar system, metrics dashboard), full suite green, PRODUCTION verdict or NOT-READY.
- **Tier C (React/Vite/Next.js): separate future milestone**, only after a macOS OS-sandbox with enforced timeout/memory/network is proven. Not in this milestone.

---

## 10. Acceptance tests

**Deterministic (unit):**
- Schema: ProjectArtifact v2 round-trips; v1 artifacts still decode.
- Dependency resolver: approved `three@<pin>` → vendored path; unknown lib → reject; integrity mismatch → reject.
- Import-map completeness: every bare `import` specifier maps to a vendored path; a remote `import "https://…"` → invalid.
- Validation: syntax error → invalid; missing dep → invalid then repaired; runtime console error (mocked) → invalid.
- Routing: "interactive 3D earth" / "three.js solar system" → project.generate(threejs); "static landing page" → project.generate(static); "next.js dashboard" → unsupported/explain; "make me a website" → clarify (supported tiers only). Tier-0 false-exec = 0.
- Headers: artifact responses carry CSP + nosniff; `connect-src 'none'` by default.

**Live (guarded):**
- *Acceptance request:* "Create an interactive rotating 3D Earth with earthquake markers." → Three.js ProjectArtifact, deps resolve to vendored `three`, sandboxed preview loads, WebGL context acquired, rotates, no uncaught errors; artifact persists after preview close; no network egress (offline test: unplug/deny → still renders geometry; remote data only if explicitly permissioned).
- Solar-system + metrics-dashboard analogues.
- Record repair attempts, selected model, latency, validation stages.

---

## 11. esh vs Ashex boundary (must hold)

| | esh (this milestone) | Ashex (out of scope) |
|---|---|---|
| Generate a project artifact | ✅ | |
| Validate + bounded repair (≤2) | ✅ | |
| Preview in disposable isolated runtime | ✅ | |
| Vendored, pinned, allowlisted deps | ✅ | |
| Arbitrary `npm install` of model-invented packages | ❌ | (Tier C install is pinned/sandboxed, still esh; arbitrary = Ashex) |
| Modify the user's repository | ❌ | ✅ |
| Run arbitrary shell commands | ❌ | ✅ |
| Deploy / inspect production | ❌ | ✅ |
| Autonomous multi-step iterate-until-done | ❌ (bounded repair only) | ✅ |

esh produces a **disposable-preview, durable-artifact** result from a single request with bounded self-correction. The moment work requires touching the user's environment, running arbitrary commands, deploying, or open-ended autonomy, it is **Ashex**.

---

## Summary recommendation
1. Adopt **ProjectArtifact v2** as an additive schema keyed on a generic `runtimeRequirements` abstraction, not framework names.
2. First managed tier = **Tier B (Three.js / browser-module)** — browser-only, no Node, extends the trusted iframe pipeline.
3. Dependency policy = **curated + pinned + integrity-verified + vendored offline**, resolver rejects the unknown; **network off by default** (CSP `connect-src 'none'`).
4. Harden the server (CSP/nosniff/frame-ancestors) and activate the dormant `.previewReady`/`.managed`/`.explicitFull` extension points.
5. Progressive validation + **bounded** repair; no autonomous debugging agent.
6. **Tier C (Node) is a separate future milestone** gated on a proven macOS OS-sandbox; **Tier D is Ashex.**
