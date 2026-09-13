# esh — iOS Portability Audit (M0)

**Milestone:** esh — iOS / Apple Platform Runtime SDK · **M0 — iOS Portability Audit**
**ClickUp:** parent `86eywc1w1`, subtask `86eywc269`
**Spec of record:** [`docs/IOS_RUNTIME_SPEC.md`](IOS_RUNTIME_SPEC.md) §10 (Phase 0)
**Status:** Complete — audit only. **No source or manifest was changed.** This is a static classification plus a build/test baseline; the actual portability work is M1+.
**Repo state audited:** branch `main` @ `336bfd7` (esh 2.3.0), Swift 6.3.3 toolchain, macOS 26 host.

---

## 0. How to read this document

This audit answers the M0 exit criterion from the spec:

> We know exactly which files prevent `EshCore` from compiling for iOS and what boundary each should move behind.

It classifies every relevant source area, inventories each concrete iOS blocker (with the required per-blocker fields), identifies the one structural seam that gates everything, proposes the smallest clean target split, and lists corrections the live codebase forces onto the written spec.

**Scope guardrail (from the milestone):** esh is the *local intelligence runtime*; Ashex is the *agent/orchestrator*. Several files in `EshCore` today are agent-adjacent (context indexing, agent tool loops, workspace location). This audit flags them but **does not** propose moving Ashex responsibilities into or out of esh — that is not an M0 decision.

---

## 1. Executive summary

The codebase is in **much better shape for iOS than the spec assumes.** The reusable contracts are already cleanly separated as protocols, the Apple Foundation Models backend is already a first-class, subprocess-free `InferenceBackend`, and the router/scheduler/model-fit logic is pure Foundation. The macOS-only execution machinery (subprocess, Python bridge, llama-server, host probes) is concentrated in a small, well-named set of files rather than smeared through the core.

Headline findings:

- **`EshCore` has exactly one external SwiftPM dependency: `swift-syntax`.** Everything MLX/TTS-related (`TTSMLX`, `mlx-audio-swift`, and the transitive `mlx-swift`, `swift-transformers`, `swift-nio`, … in `Package.resolved`) is pulled **only** by the `esh` executable target, never by `EshCore`. iOS portability of the core is **not** blocked by the MLX Swift stack.
- **There is no AppKit / Cocoa / `NSWorkspace` / `NSApplication` anywhere in `EshCore`** (0 matches). This is the usual iOS killer and it is simply absent.
- **Subprocess execution (`Process` + `Pipe`) lives in exactly 7 files**, all of them backend/host-probe implementations, never in a contract.
- **`FoundationModels` is imported in exactly one file** (`Services/AppleIntelligenceService.swift`), already guarded by `#if canImport(FoundationModels)`. The Apple backend (`Backends/Apple/AppleBackend.swift`) is otherwise pure and portable.
- **The single most important structural blocker is `Services/InferenceBackendRegistry.swift`**, which eagerly constructs `MLXBackend` + `LlamaCppBackend` + `AppleBackend` as stored properties. As long as that type is reachable from an iOS build, the subprocess backends are dragged in with it. This is the seam M1 must cut.
- **`#available(macOS 26.0, *)` gates Apple FM availability in two places** and must be generalized to `iOS 26 / visionOS / macOS 26` — but the surrounding structure (typed `AppleIntelligenceAvailability`, honest failure) is already exactly what the spec asks for.

**Bottom line:** M1 is a *boundary extraction*, not a rewrite. The portable core is ~80% already portable by construction; the blockers are a compact list (below) plus one registry refactor.

---

## 2. Build & test baseline

Builds were redirected off the intended `.build` location because that symlink targets an **unmounted external volume**:

```
.build -> /Volumes/Sviat SSD/esh-build/turboquant-source   # NOT MOUNTED during audit
```

All commands below used a local `--scratch-path` instead.

| Check | Command | Result |
|---|---|---|
| macOS build | `swift build --scratch-path <local>` | **PASS** (exit 0) — full graph incl. MLX/TTS deps compiled |
| macOS tests | `swift test --scratch-path <local>` | **619 tests / 104 suites, 4 issues (exit 1)** — see below |

**All 4 test failures are environment artifacts, not code regressions** (nothing in this milestone was changed):

| Failing test | File | Root cause |
|---|---|---|
| `installRecordsBaseModelForPEFTAdapterRepo()` | `HuggingFaceModelDownloaderTests.swift:7` | Model storage volume `/Volumes/Sviat SSD/esh-models` **not mounted** |
| `installRejectsSafetensorsRepoWithoutConfigOrAdapterMetadata()` | `HuggingFaceModelDownloaderTests.swift:113` | Same unmounted volume — error text mismatch |
| `installFailsWhenDownloadedFileSizeDoesNotMatchMetadata()` | `HuggingFaceModelDownloaderTests.swift:162` | Same unmounted volume — `StorageError` thrown before the assertion path |
| `agentToolServiceRunsExplicitVerificationTools()` | `AgentLoopTests.swift:147` | Agent tool loop returned `isError == true`; env-dependent (agent verification tooling), unrelated to portable core |

**615/619 pass.** The 3 downloader failures are a direct consequence of the disconnected `Sviat SSD` volume (the same volume the build path points at). The 1 agent-loop failure is in agent-tooling territory (Ashex-adjacent), not in any file this audit classifies as portable.

> ⚠️ **Honesty note:** I cannot claim "the macOS suite is green" — it is green *except for* four environment-driven failures. To establish a clean green baseline, mount `Sviat SSD` (or run `esh storage use-internal`) and re-run; then confirm whether `agentToolServiceRunsExplicitVerificationTools` is genuinely env-flaky or a real defect. This should be done before M1 lands, so M1's "existing macOS tests pass" gate has a trustworthy reference.

> 💽 **Environment caveat:** the host system volume was near-full; the redirected build consumed the remaining space and had to be cleaned up. Prefer building on the external SSD (mounted) or a volume with tens of GB free — the full dependency graph (mlx-swift + transformers + nio + syntax) is large.

---

## 3. Classification legend

| Class | Meaning |
|---|---|
| **PORTABLE** | Pure Swift/Foundation contracts or logic; compiles & runs on iOS as-is. |
| **APPLE-SHARED** | Uses an Apple framework available on both macOS and iOS (FoundationModels, Vision, AVFoundation, CoreGraphics, ImageIO, Darwin/mach). Compiles on iOS; may need availability/semantic tuning. |
| **MACOS-ONLY** | Depends on a mechanism absent or forbidden on iOS (subprocess, `/bin`,`/usr/bin`, Python, llama-server, IOKit `IOAccelerator`, localhost server, host process inspection) — must be unreachable from an iOS build. |
| **IOS-IMPLEMENTATION-NEEDED** | New iOS-side code required (facade, device profile, sandbox storage root, memory-pressure source, platform-conditional wiring). |
| **UNKNOWN** | Compiles but its iOS role/necessity needs a product decision (e.g. swift-syntax weight, quantization tooling). |

---

## 4. Dependency audit (`Package.swift` / `Package.resolved`)

Current manifest: `platforms: [.macOS(.v14)]`, products `EshCore` (library) + `esh` (executable), test targets `EshCoreTests`, `EshUITests`.

| Dependency | Consumed by | iOS support | Class / note |
|---|---|---|---|
| `swift-syntax` 603.0.2 (`SwiftParser`, `SwiftSyntax`) | **`EshCore`** (only `Services/SymbolExtractor.swift`) | Yes (pure Swift, all platforms) | **PORTABLE** but heavy. Only real use is code-symbol extraction (context/agent-adjacent). See §7 UNKNOWN — candidate to keep out of the minimal iOS core. |
| `TTSMLX` 0.3.3 | `esh` target only | — | Not in the iOS core path. No action for M1. |
| `mlx-audio-swift` (pinned rev) | `esh` target only | — | Not in the iOS core path. |
| transitive: `mlx-swift`, `mlx-swift-lm`, `swift-transformers`, `swift-huggingface`, `swift-jinja`, `swift-nio`, `swift-numerics`, `swift-atomics`, `swift-collections`, `swift-system`, `swift-crypto`, `swift-asn1`, `yyjson`, `eventsource` | via `TTSMLX` / `mlx-audio-swift` (i.e. `esh` target) | mixed | **Not reachable from `EshCore`.** They resolve into `Package.resolved` because they are in the overall graph, but the `EshCore` library does not link them. iOS core build is unaffected. |

**Key conclusion:** adding `.iOS(...)` to the platforms list does **not** force any MLX/TTS/NIO dependency onto the portable core. The manifest change is safe *provided* the subprocess backends are made unreachable (the registry seam, §6).

**Minimum iOS deployment target:** driven by Apple Foundation Models, which requires **iOS 26 / macOS 26** (`SystemLanguageModel`, `LanguageModelSession`). The *portable contracts* themselves need nothing newer than iOS 15-ish, but the first real backend (Apple FM) pins the shipping SDK floor to **iOS 26** for the FM-bearing target. Recommend: portable core `.iOS(.v16)` (or lower if it compiles), Apple-runtime target gated at iOS 26 via `#available`.

---

## 5. Per-area classification

Counts are `.swift` files per directory in `Sources/EshCore/` (231 total) and `Sources/esh/` (74 total).

| Area | Files | Class | Notes |
|---|---|---|---|
| `Protocols/` | 12 | **PORTABLE** | `InferenceBackend`, `BackendRuntime`, `ModelStore`, `ModelCatalog`, `ModelDownloader`, `CacheStore`, `SessionStore`, `CompatibilityChecking`, … All pure contracts. This is the layer the spec calls the portable core — it already is. |
| `Domain/` | 44 | **PORTABLE** | Value types: `ModelSpec`, `ModelInstall`, `ChatSession`, `GenerationConfig`, `CapabilityRequest`, `Metrics`, `BackendKind`, `EshConfig`, `EngineStatus`, `ProjectArtifactV2`, … All `import Foundation` only (verified — the `python`/`localhost`/`127.0.0.1` grep hits here are config keys, enum cases, and comments, not code paths). |
| `Routing/` | 10 | **PORTABLE** | `CapabilityRouterService`, `DeterministicIntentRouter`, `SemanticIntentRouter`, `IntentResolver`, `RouterEvidence`, `RoutingOutcome`, `CapabilityIntent`. Foundation-only. This is the "one conceptual router" the spec wants preserved cross-platform. |
| `Runtime/` | 4 | **mostly PORTABLE** | `ExecutionPlan`, `RuntimeLifecycle`, `CapabilityProvider` (pure contracts — its `FoundationModels` grep hit is a comment). `RuntimeLifecycleManager.swift` calls `SystemMemory.snapshot()` → APPLE-SHARED seam (see §7). |
| `Services/` (scheduler/fit) | — | **PORTABLE** | `SchedulerService`, `CapabilityScheduler`, `ModelFitService`, `ImageModelFitService`, `ImageUpscaleFitService` — all `import Foundation` only. Model Fit takes host numbers as inputs; it does **not** probe the host itself. Good — matches spec Phase 4 intent. |
| `Backends/Apple/` | 1 | **APPLE-SHARED / PORTABLE** | `AppleBackend.swift` — pure, subprocess-free, delegates to `AppleIntelligenceService`. Already a model `InferenceBackend`. First iOS backend. |
| `Services/AppleIntelligenceService.swift` | 1 | **APPLE-SHARED** | Only `FoundationModels` importer; guarded. **Needs iOS availability generalization** (§7 blocker B1). |
| `Capabilities/AppleVisionOCRProvider.swift`, `AVFoundationVideoExtractor.swift` | 2 | **APPLE-SHARED** | Vision / AVFoundation / CoreMedia / ImageIO / CoreGraphics, all `canImport`-guarded and iOS-available. Not needed for M1 but not blockers. |
| `Utils/SystemMemory.swift` | 1 | **APPLE-SHARED (semantic caveat)** | mach `host_statistics64` + `ProcessInfo.physicalMemory`. Compiles on iOS but "available memory" semantics differ (iOS should use `os_proc_available_memory()`); feeds device profile in Phase 4. |
| `Utils/SystemGPU.swift` | 1 | **MACOS-ONLY** | `import IOKit` + `IOServiceMatching("IOAccelerator")`. Blocker G1. |
| `Utils/SystemProcesses.swift` | 1 | **MACOS-ONLY** | Spawns `/bin/ps`. Blocker P2. |
| `Utils/ProcessRunner.swift` | 1 | **MACOS-ONLY** | Generic `Process`+`Pipe` runner. Blocker P1. |
| `ExecutablePath.swift`, `RuntimePathResolver.swift` | 2 | **MACOS-ONLY (purpose)** | `_NSGetExecutablePath` compiles on iOS, but purpose is locating bundled Python/MLX/llama runtime + `/usr/bin/python3` fallback → macOS packaging. Blocker R1/R2. |
| `Backends/MLX/` | 7 | **MACOS-ONLY** | Python-subprocess bridge (`MLXWorker`, `MLXRuntime`, `MLXBackend`, `MLXBridge`, `MLXPersistentRuntime`, `MLXModelLocator`, `MLXCacheSnapshotCodec`). Blocker set M-MLX. |
| `Backends/GGUF/` | 4 | **MACOS-ONLY** | `llama-server` subprocess + localhost (`LlamaCppBackend`, `LlamaServerProcess`, `LlamaAuxServerProcess`, `LlamaServerRuntime`). Blocker set M-GGUF. Matches spec §15 (stays macOS; iOS needs embedded backend later). |
| `Backends/Speech/` | 2 | **MACOS-ONLY** | `SpeechWorker`/`SpeechRuntimeManager` Python subprocess. Voice is a non-goal for M1. |
| `Services/InferenceBackendRegistry.swift` | 1 | **MACOS-ONLY → IOS-IMPLEMENTATION-NEEDED** | **The seam.** Constructs all three backends. Must become platform-conditional / injected so iOS wires Apple only. Blocker S1 (highest priority). |
| `Services/OpenAICompatibleLocalServer.swift`, `OpenAICompatibleService.swift`, `AnthropicCompatibleService.swift` | 3 | **MACOS-ONLY (policy)** | Localhost server surface. `esh serve` / local HTTP server is an explicit iOS non-goal. `Network` framework itself is portable, but the server role is not shipped on iOS. |
| `Capabilities/EmbeddingProviders.swift` | 1 | **MACOS-ONLY** | Uses `LlamaAuxServerProcess` (subprocess). |
| `Capabilities/` (media providers) | ~13 | **MACOS-ONLY** | ImageGen/ImageEdit/ImageUpscale/AudioGen/AudioDiarization/Segmentation/VideoUnderstanding/VisionUnderstand/ProjectGen/WebArtifact/BrowserModule/TextToSVG — Python-bridge shellouts. Full media/vision/voice stack is an M1 non-goal. Exceptions already listed as APPLE-SHARED (`AppleVisionOCRProvider`) or portable (`SVGScene`, `WebLibRegistry`, `WebLibRegistry` uses CryptoKit — portable). |
| `Engines/` | 2 | **MACOS-ONLY** | On-demand `pip`/Python engine install. |
| `Voice/` | 10 | **MACOS-ONLY** | WebSocket server/client + speech workers (localhost + subprocess). Non-goal M1. |
| `Web/` | 2 | **MACOS-ONLY** | Web studio server. |
| `Terminal/` | 3 | **MACOS-ONLY (scope)** | TUI/CLI formatting; belongs with the `esh` executable, not the iOS SDK. |
| `Benchmark/` | 5 | **MACOS-ONLY (dev tooling)** | Drives real backends for benchmarking. |
| `Persistence/` | 14 | **PORTABLE (config caveat)** | `File*Store` on `FileManager` — compiles on iOS. **But** storage-root/external-volume assumptions (`PersistenceRoot`, `StorageConfigStore`) are macOS-shaped (`/Volumes/...`, `esh storage use-internal`). iOS needs an app-sandbox root (spec §16). IOS-IMPLEMENTATION-NEEDED for the root, not the stores. |
| `Downloads/` | 5 | **PORTABLE** | `URLSession` + HuggingFace. Compiles on iOS; downloads gated by intent per spec §16. |
| `Compression/TurboQuant/` | 4 | **UNKNOWN** | `TurboQuantBridge` is Foundation-only (compiles) but is quantization tooling; iOS role unclear. Likely macOS dev-time. Decide in M5/M6. |
| `Services/SymbolExtractor.swift` | 1 | **UNKNOWN** | Sole `swift-syntax` consumer; code-context (agent-adjacent). See §7. |
| `esh/` (executable) | 74 | **MACOS-ONLY** | CLI, TUI, web experience, install/bootstrap, TTS. Not part of the iOS SDK. Imports `TTSMLX`, `Metal`, `Darwin`. Stays macOS. |

---

## 6. The critical seam: `InferenceBackendRegistry`

```swift
// Sources/EshCore/Services/InferenceBackendRegistry.swift
public struct InferenceBackendRegistry: Sendable {
    private let mlxBackend: MLXBackend        // ← drags in Python-subprocess code
    private let ggufBackend: LlamaCppBackend  // ← drags in llama-server subprocess
    private let appleBackend: AppleBackend    // ← the only iOS-safe one
    ...
    public func backend(for install: ModelInstall) -> any InferenceBackend {
        switch install.spec.backend {
        case .mlx:  mlxBackend
        case .gguf: ggufBackend
        case .onnx: mlxBackend
        case .apple: appleBackend
        }
    }
}
```

Because `MLXBackend` and `LlamaCppBackend` are **stored properties constructed in `init`**, any iOS target that can reach `InferenceBackendRegistry` must compile the subprocess backends. This single type is what makes the core "macOS-only" in practice.

**Recommended M1 fix (smallest clean cut):** invert construction so the set of backends is *supplied* rather than hard-wired. Options, in the spec's preferred priority order (protocol/injection > platform target > conditional compilation):

1. **Injection (preferred):** registry holds `[BackendKind: any InferenceBackend]` (or a resolver closure) provided by a platform assembly. macOS assembly registers MLX+GGUF+Apple; iOS assembly registers Apple only. The registry type itself becomes fully PORTABLE.
2. **Platform target:** move MLX/GGUF backends into `EshMacRuntime`; the registry lives in core and is populated by whichever runtime target is linked.
3. **Conditional compilation (fallback):** `#if os(macOS)` around the MLX/GGUF properties and their `case`s. Acceptable as a first step, but option 1 is cleaner and testable.

This same inversion cleanly supports "explicit backend/model pinning respected" and "Auto reuses existing scheduler/router" — the router keeps working; only the *candidate set* narrows by platform, exactly as spec §18 requires.

---

## 7. Blocker inventory (required per-blocker detail)

Each blocker below is documented with: **file · why it blocks iOS · belongs in portable core? · proposed boundary · change now (M1) or later.**

### S1 — Backend registry wiring (the gate)
- **File:** `Sources/EshCore/Services/InferenceBackendRegistry.swift`
- **Why it blocks iOS:** eagerly instantiates `MLXBackend` + `LlamaCppBackend`, transitively compiling all subprocess/Python code into any target that references it.
- **Belongs in portable core?** The *registry abstraction* yes; the *concrete macOS backends* no.
- **Proposed boundary:** dependency-injected backend set; macOS vs iOS assemblies register different backends (§6).
- **When:** **M1 (now).** Nothing else can compile for iOS until this is cut.

### B1 — Apple FM availability is macOS-gated
- **File:** `Sources/EshCore/Services/AppleIntelligenceService.swift`
- **Why it blocks iOS:** availability + generation are guarded by `if #available(macOS 26.0, *)` only; on iOS these branches fall through to "unavailable / unsupported OS" even on eligible devices. Also `AppleIntelligenceAvailability.unsupportedOS` detail text says "macOS".
- **Belongs in portable core?** Yes — it is already the shared, guarded Apple entry point (keep it single, per spec §12 "do not duplicate the Apple provider").
- **Proposed boundary:** generalize to `#available(iOS 26, macOS 26, visionOS 26, *)`; make `deviceNotEligible`/`unsupportedOS` detail text platform-neutral; keep `#if canImport(FoundationModels)`.
- **When:** **M1/M2 (now for compile; M2 for real device semantics).**

### P1 — Generic subprocess runner
- **File:** `Sources/EshCore/Utils/ProcessRunner.swift`
- **Why:** `Foundation.Process` + `Pipe`; `Process` is unavailable on iOS.
- **Portable core?** No.
- **Boundary:** move to `EshMacRuntime`; nothing in the portable core should call it.
- **When:** M1 (isolate).

### P2 — Top-RAM-consumer probe
- **File:** `Sources/EshCore/Utils/SystemProcesses.swift`
- **Why:** spawns `/bin/ps` via `Process`/`Pipe`; both the binary and subprocess are iOS-forbidden.
- **Portable core?** No.
- **Boundary:** `EshMacRuntime`. On iOS, "what's using RAM" is not available; the device-profile abstraction (§ Phase 4) returns nil/estimate instead.
- **When:** M1 (isolate); iOS replacement in M5.

### G1 — GPU inspection via IOKit
- **File:** `Sources/EshCore/Utils/SystemGPU.swift`
- **Why:** `import IOKit` + `IOServiceMatching("IOAccelerator")` / `IORegistryEntryCreateCFProperties` — the IORegistry matching API is macOS-only in practice.
- **Portable core?** No.
- **Boundary:** `EshMacRuntime`; behind a `DeviceProfile`/GPU-info protocol whose iOS impl reports nil or Metal-derived info.
- **When:** M1 (isolate); iOS device profile in M5.

### R1 — Executable path discovery
- **File:** `Sources/EshCore/ExecutablePath.swift`
- **Why:** compiles on iOS (`_NSGetExecutablePath` via Darwin), but its purpose — locate a bundled Python/MLX/llama runtime relative to `bin/` — is a macOS packaging concern with no iOS meaning.
- **Portable core?** No (purpose, not compilation).
- **Boundary:** `EshMacRuntime` (used only by macOS runtime discovery).
- **When:** M1 (isolate).

### R2 — Python / venv / bridge path resolution
- **File:** `Sources/EshCore/RuntimePathResolver.swift`
- **Why:** resolves `python3`, `.venv/bin/python`, `Tools/mlx_vlm_bridge.py`, `/usr/bin/python3` — Python is an explicit iOS non-goal.
- **Portable core?** No.
- **Boundary:** `EshMacRuntime`.
- **When:** M1 (isolate).

### M-MLX — MLX Python-bridge backend (7 files)
- **Files:** `Sources/EshCore/Backends/MLX/{MLXBackend,MLXBridge,MLXRuntime,MLXWorker,MLXPersistentRuntime,MLXModelLocator,MLXCacheSnapshotCodec}.swift`
- **Why:** drive a persistent Python worker (`Process`/`Pipe`, `mlx_vlm_bridge.py`). No Python/subprocess on iOS.
- **Portable core?** No.
- **Boundary:** `EshMacRuntime`. (If `MLXCacheSnapshotCodec` turns out to be pure data with no MLX dep, it may move to core — verify during extraction.)
- **When:** M1 (isolate). Remains the macOS MLX path indefinitely.

### M-GGUF — llama-server backend (4 files)
- **Files:** `Sources/EshCore/Backends/GGUF/{LlamaCppBackend,LlamaServerProcess,LlamaAuxServerProcess,LlamaServerRuntime}.swift`
- **Why:** spawn `llama-server` subprocess and talk to it over localhost. Subprocess + local server both iOS-forbidden; matches spec §15 (macOS keeps the spawned server).
- **Portable core?** No.
- **Boundary:** `EshMacRuntime`. iOS GGUF, if ever, is the *embedded in-process* `LlamaCppEmbeddedBackend` (spec §15) — a separate later target (M6/M7), not this code.
- **When:** M1 (isolate).

### M-SPEECH / servers / media (grouped)
- **Files:** `Backends/Speech/*`, `Services/OpenAICompatible*`, `Services/AnthropicCompatibleService.swift`, `Capabilities/EmbeddingProviders.swift`, most `Capabilities/*` media providers, `Engines/*`, `Voice/*`, `Web/*`.
- **Why:** subprocess/Python/localhost-server; all are M1 non-goals (voice, image, vision, `esh serve`).
- **Portable core?** No.
- **Boundary:** `EshMacRuntime` (or stay with the `esh` executable for pure CLI/web surfaces).
- **When:** isolate as they fall on the macOS side of the registry cut; no iOS work in this milestone.

### Semantic-only (compiles, but review)
- **`Utils/SystemMemory.swift` (APPLE-SHARED):** compiles on iOS; "available memory" via `host_statistics64` is not the right iOS signal. Feed the Phase-4 device profile with `os_proc_available_memory()` on iOS. Change **later** (M5).
- **`Persistence/PersistenceRoot.swift` + `StorageConfigStore.swift` (PORTABLE, config caveat):** compile on iOS, but default roots/external-volume logic are macOS-shaped. iOS needs a sandbox root. Change **later** (M1 tail / M2), not a compile blocker.

### UNKNOWN (product decisions)
- **`Services/SymbolExtractor.swift` + `swift-syntax`:** the only core user of a heavy dependency, for code-symbol extraction (context/agent-adjacent, arguably closer to Ashex than to an intelligence runtime). `swift-syntax` compiles for iOS but adds meaningful binary weight. **Decision for M1:** keep `SymbolExtractor`/`swift-syntax` **out** of the minimal portable iOS core (leave it in a macOS/context target) unless an iOS consumer truly needs it. Do not add it to the iOS SDK "for free."
- **`Compression/TurboQuant/*`:** Foundation-only, compiles, but quantization tooling with no clear iOS runtime role. Revisit at M5/M6.

---

## 8. Recommended minimal module / target split

The spec (§6) lists an aspirational 5-target end state but explicitly warns against fragmenting for aesthetics. The smallest split that satisfies "core builds for iOS, macOS intact, no platform leakage" is **three targets**, reached in two steps:

**Step 1 (M1, lowest-risk):** keep `EshCore` as one target, add `.iOS` to platforms, and cut the registry seam (S1) with **conditional compilation** around MLX/GGUF (properties, `case`s, and the backend files). Isolate P1/P2/G1/R1/R2 the same way. This gets an iOS compile with the least churn and is fully reversible.

**Step 2 (M1→M3, the clean end state):** extract the macOS execution machinery into its own target so the core has *no* `#if os` in business logic:

```
EshCore         — PORTABLE contracts + Domain + Routing + Scheduler + ModelFit
                  + Apple backend + AppleIntelligenceService (canImport-guarded)
                  + portable Persistence/Downloads.  Builds for iOS & macOS.
                  (swift-syntax NOT linked here — see §7.)

EshMacRuntime   — macOS-only: MLX/GGUF/Speech backends, ProcessRunner,
                  SystemProcesses, SystemGPU, RuntimePathResolver,
                  ExecutablePath, servers, media/voice/web providers,
                  SymbolExtractor + swift-syntax.  macOS only.

EshRuntime      — app-facing facade (actor) over EshCore's router/scheduler;
                  a platform assembly injects the available backends.
                  Builds for iOS & macOS.  (M3.)

esh             — executable; depends on EshMacRuntime + EshRuntime. macOS only.
```

Do **not** create `EshAppleRuntime` as a separate target yet: the Apple backend is small and already lives cleanly in `EshCore` behind `canImport(FoundationModels)`. A distinct Apple-runtime target is only worth it if/when Apple-platform code diverges — premature now.

---

## 9. Exact blockers to M1

M1 = "portable core compiles for iOS; macOS intact." The gating list, in order:

1. **S1** — invert `InferenceBackendRegistry` construction (injection/conditional) so MLX+GGUF are not compiled/reached on iOS. *Everything else depends on this.*
2. **Isolate the subprocess/host files** so they are not in the iOS build graph: `ProcessRunner` (P1), `SystemProcesses` (P2), `SystemGPU`/IOKit (G1), `RuntimePathResolver` (R2), `ExecutablePath` (R1), and the `Backends/{MLX,GGUF,Speech}` sets.
3. **B1** — generalize `AppleIntelligenceService` availability to iOS 26 (compile-correct; real-device semantics in M2).
4. **Manifest** — add `.iOS(...)` platform; ensure `EshCore` links only iOS-safe deps (exclude `swift-syntax`/`SymbolExtractor` from the iOS core per §7).
5. **Verify** with a real iOS-simulator compile of the portable core (see §11) — this audit did **not** perform an iOS build (it requires the manifest change that is itself M1 work).

Non-gating for M1 (defer): iOS storage root, `SystemMemory` iOS semantics, device profile, memory-pressure source, facade (M3), demo (M4).

---

## 10. Corrections to `docs/IOS_RUNTIME_SPEC.md` from the live codebase

The spec is largely accurate. Live-code adjustments:

1. **The spec is missing from the repo.** `docs/IOS_RUNTIME_SPEC.md` did not exist in the tree at audit time (it was supplied out-of-band). It is a "required repo document" (spec §27); it has been added alongside this audit so the milestone has an in-repo source of truth. *(Content unchanged from the supplied spec.)*
2. **swift-syntax scope.** The spec's "audit `Package.resolved`" implies a large dependency surface on the core. In reality **`EshCore`'s only external dependency is `swift-syntax`**; all MLX/TTS/NIO deps belong to the `esh` executable target. The spec should note that the *core* dependency surface is tiny and that `swift-syntax` (via `SymbolExtractor`) is the one weight to consciously exclude from iOS.
3. **No AppKit.** The spec lists `AppKit` among things to search for; there is **none** in `EshCore`. Worth recording as a positive finding rather than an open risk.
4. **`Process` footprint is smaller than implied.** Subprocess use is 7 files, all backend/host-probe — not diffuse. The spec's "EshCore currently mixes … `Process`, pipes, host-process inspection" is true but the mixing is shallow and localized.
5. **`InferenceBackendRegistry` is *the* seam.** The spec describes the boundary conceptually; concretely, this one file's stored-property construction is the mechanism that makes the core macOS-only. Recommend naming it explicitly in the spec as the M1 focal point.
6. **`ExecutablePath.swift` compiles on iOS** (`_NSGetExecutablePath` exists via Darwin) — it is macOS-only by *purpose*, not by compilation. Minor: the spec's "executable discovery" blocker is a scope/isolation issue, not a compile error.
7. **`SystemMemory` compiles on iOS** but with wrong semantics; the spec's Phase-4 "never pretend memory availability is more precise than iOS exposes" should call out replacing `host_statistics64`-derived "available" with `os_proc_available_memory()` on iOS.
8. **Deployment target is pinned by Apple FM to iOS 26**, not by the contracts. The spec's "derive the minimum from real dependencies" resolves to: portable core low (≈iOS 16), Apple-FM path iOS 26.
9. **Test baseline caveat.** The spec's acceptance "existing macOS tests pass" needs an environment note: the suite depends on the external `Sviat SSD` volume for model-storage tests; a clean green requires that volume mounted (or `esh storage use-internal`).

---

## 11. Exit criterion status

> **Spec §10 exit:** "We know exactly which files prevent `EshCore` from compiling for iOS and what boundary each should move behind." — **Met.** See §6, §7, §9.

Caveats / what M0 deliberately did **not** do (respecting the "stop at the M0 gate; no refactor before audit" instruction):

- **No iOS build was executed.** A real `xcodebuild -sdk iphonesimulator` / `swift build` for iOS requires adding `.iOS` to `Package.swift` and cutting S1 — that is M1 work, not a Phase-0 static audit. Recommended **first M1 action**: make the manifest + S1 change on a branch and run the iOS-simulator compile to confirm this audit's blocker list is complete (the compiler will surface anything static analysis missed — e.g. a stray `Process` reference reached transitively).
- **No code or manifest changed.**
- The 4 baseline test failures are environment-driven (§2); resolve the `Sviat SSD` mount before treating the macOS suite as the M1 regression reference.

---

## 12. Milestone acceptance-criteria pre-check (informational)

Where the milestone's initial acceptance criteria stand after M0 (audit-time assessment, not implementation):

| Criterion | M0 assessment |
|---|---|
| Portable core compiles for iOS | **Not yet** — gated by S1 + manifest (M1). Structurally feasible. |
| Existing macOS behavior operational | **Yes** — build green; test failures env-only. |
| macOS subprocess unreachable from iOS | **Design ready** (§6/§8); not yet implemented. |
| No Python/child-proc/local server on iOS | **Achievable** — all such code is on the macOS side of the registry cut. |
| Apple FM as an esh backend on iOS | **Backend already exists**; needs B1 availability generalization. |
| Honest typed unavailable status | **Already present** (`AppleIntelligenceAvailability` + typed errors). |
| `localOnly` enforceable | **Already honored** by `AppleBackend` (strictly on-device; no PCC/cloud path). |
| Explicit pinning respected | **Already** — `AppleProvider.reservedModelIDs` never silently substitutes a pinned download. |
| Auto reuses scheduler/router | **Yes** — pure-Foundation router/scheduler is portable; only candidate set narrows. |
| `EshRuntime` facade | **Not yet** (M3). |
| Selected backend metadata observable | Partially — `BackendKind`/`Metrics` exist; facade to surface it (M3). |
| Cancellation through public API | Backends use `AsyncThrowingStream`; facade must propagate (M3). |
| Existing macOS tests pass | **Yes, modulo environment** (§2). |
| iOS simulator build in CI | **Not yet** (M4); `.github/workflows/ci.yml` present to extend. |
| README not overclaiming iOS | **OK** — unchanged; keep it that way until M2+. |
| No Ashex responsibilities added | **Held** — audit adds nothing; flags agent-adjacent code without moving it. |

---

*End of M0 audit. Recommended next action: open the M1 branch, make the `Package.swift` + `InferenceBackendRegistry` (S1) change, and run the iOS-simulator compile to validate this blocker list — then return to the M1 gate.*

---

# M1 — Compiler-Validated Findings & Implementation Record

**Added after M1** (branch `feat/ios-portable-core-m1`). This section records what the iOS compiler actually proved, corrects M0 assumptions it disproved, and documents the boundary that was implemented. M0 above is left intact as the original static audit.

## M1.1 Result

- **iOS Simulator build of `EshCore`: GREEN.** `xcodebuild -scheme EshCore -destination 'generic/platform=iOS Simulator' build` → `** BUILD SUCCEEDED **` (exit 0, 0 errors), reproduced from a **clean** DerivedData (`clean build`).
- **macOS: unchanged.** `swift build` clean; `swift test` → **619 tests / 104 suites pass** (exit 0), identical to the pre-M1 baseline (the M0 "4 failures" were the unmounted external SSD, now confirmed environment-only).
- Reached via **19 iOS compile rounds**, each fixing exactly what the compiler reported — no speculative guarding.

## M1.2 M0 assumptions the compiler DISPROVED or REFINED

1. **`ExecutablePath.swift` does NOT compile on iOS.** M0 said `_NSGetExecutablePath` is available via Darwin on iOS. It is **not** resolvable in the iOS SDK. Fixed: gated `#if os(macOS)` with an `argv[0]` fallback on iOS.
2. **`PersistenceRoot` / `PathResolving` use home-dir APIs unavailable on iOS.** `FileManager.homeDirectoryForCurrentUser` is `unavailable in iOS`. Fixed: `PersistenceRoot.resolveStateRoot()` now returns `<AppSupport>/esh` on iOS (`#if os(macOS)` for the `~/.esh` + legacy-migration path); `PathResolving` switched to the cross-platform `NSHomeDirectory()` (no `#if`).
3. **`IOKit` fails at *module resolution*, before type-checking** — it was the very first blocker and masked all the `Process` errors until fixed. Confirms M0's G1 but shows the ordering.
4. **Several "macOS-only" files actually compiled fine on iOS** because they call `ProcessRunner`/`MLXBridge` (functions) rather than `Process`/IOKit directly — so the *hard compile-blocker* set is smaller than the macOS-only *policy* set. They were still isolated where they form a subsystem with true blockers, or where the platform assembly must not reach them.
5. **Mixed-concern files** — the biggest lesson: several macOS-heavy files also *defined portable shared types* the core needs. Whole-file guarding them broke the portable core (peaked at 271 cascade errors from one such case). These required **extraction**, not guarding (see M1.4).
6. **`FoundationModels`, `Vision`, `AVFoundation`, `CoreMedia`, `ImageIO`, `CoreGraphics`, `CryptoKit`, `Network`, `SwiftSyntax` all resolve for iOS** (confirms APPLE-SHARED / PORTABLE classifications). `swift-syntax` builds for iOS and stayed a core dependency for M1 (see M1.6).

## M1.3 The seam (S1), implemented

`InferenceBackendRegistry` is now **dependency-injected** and references no concrete backend type: it holds `[BackendKind: any InferenceBackend]` (`resolve(_:)` + `backend(for:)`). The default `init()` is the single platform assembly — macOS wires MLX + GGUF + Apple; **every other platform wires Apple Foundation Models only**. No subprocess backend is constructed or compiled in an iOS build.

## M1.4 Portable shared types EXTRACTED from macOS-heavy files (7 new files)

Each was a portable contract/value type colocated with macOS execution; extraction (not guarding) kept the core buildable:

| New portable file | Extracted from | Why it's portable |
|---|---|---|
| `Domain/JSONValue.swift` | `OpenAICompatibleService` | Used across Domain/Routing/Scheduler/Artifacts (caused the 271-error cascade). |
| `Domain/ContextPlanningBrief.swift` (`ContextSnippet`, `ContextPlanningBrief`) | `ContextPlanningService` | Used by `Domain/ContextPackage`, `RunStateStore`. |
| `Capabilities/DeterministicAudio.swift` (`DeterministicAudio`, `SplitMix64`) | `AudioGenProvider` | Pure DSP/WAV synthesis; used by portable routing (`IntentResolver`). |
| `Capabilities/VideoMedia.swift` (`VideoMetadata`, `VideoMediaExtractor`, `VideoFrameSampler`) | `VideoUnderstandingProvider` | Contracts implemented by the Apple-shared `AVFoundationVideoExtractor`. |
| `Capabilities/AttachmentIO.swift` (`materialize`, `stripDataURLPrefix`, `ext`) | `VisionUnderstandProvider` | Attachment/MIME helpers used by the portable `AppleVisionOCRProvider`. |
| `Capabilities/CapabilityRequestOptions.swift` (`string`) | `VideoUnderstandingProvider` | Request-option parsing used by portable web/project/SVG providers. |
| `Benchmark/ImageUpscaleBenchmarkStore.swift` (`UpscaleBenchmarkDataset`, `ImageUpscaleBenchmarkStore`) | `ImageUpscaleBenchmark` | Persisted evidence read by the portable scheduler / Model Fit; the *runner* stays macOS-only. |

## M1.5 Isolation (guards)

- **49 whole-file `#if os(macOS)` guards** — genuinely macOS-only execution: `Backends/{MLX,GGUF,Speech}/*` (13), `Utils/{ProcessRunner,SystemProcesses}` (2), the OpenAI/Anthropic **server** layer + HTTP handlers (5), `ChatModelValidator`, `SpeechToTextService`, the Python-bridge **media providers** (`ImageGeneration/ImageEdit/ImageUpscale/AudioGen/AudioDiarization/Segmentation/VisionUnderstand/VideoUnderstanding/Embedding/ImageAdapter`), `Engines/GenerativeEngineManager`, `Compression/TurboQuant/*`, the **agent/context** services (`AgentLoopService`, `AgentToolService`, `Context{Store,QueryEngine,PlanningService,PackageService,EvaluationHarness}`, `WorkspaceContextLocator`), `Doctor/Onboarding/LocalModelValidation` services, benchmark runners, `RuntimePathResolver`.
- **8 surgical guards** in otherwise-portable files: `InferenceBackendRegistry` (assembly), `ExternalInferenceService` (2 MLX-cache methods), `IntentResolver` (generative-engine install probe), `SystemMemory` (`/bin/ps` top-consumer), `SystemGPU` (`canImport(IOKit) && os(macOS)` body → `nil` on iOS), `EngineStatus` (`BridgeMLXPackageDoctor`), `PersistenceRoot` (state root), `ExecutablePath` (`_NSGetExecutablePath`).
- **2 cross-platform fixes (no `#if`):** `PathResolving` (`NSHomeDirectory()`), `AppleIntelligenceService` (availability generalized to `iOS 26 / visionOS 26 / macOS 26`, detail text made platform-neutral).

**Static verification:** no `Process(`, `import IOKit`, `_NSGetExecutablePath`, or `homeDirectoryForCurrentUser` is reachable outside an `os(macOS)` region — confirmed by grep *and* by the green iOS build (the compiler would error otherwise).

## M1.6 Remaining conditional-compilation debt & the EshMacRuntime question

M1 stayed a **single `EshCore` target** with ~57 guard sites. This is the audit's Step-1 (conditional compilation) and it is honest and green, but it is real debt:
- `swift-syntax` remains a core dependency (only `SymbolExtractor` uses it) and now builds for iOS too — not yet excluded.
- ~49 whole-file-guarded files are dead weight in an iOS build.

The compiler did **not** prove the single-target boundary *insufficient* (iOS is green, macOS is 619/619), so per the M1 constraint no target split was performed. **Recommended follow-up (post-M1, e.g. M1.5 or alongside M3):** extract the 49 whole-file-guarded files into an `EshMacRuntime` target (and move `SymbolExtractor` + `swift-syntax` there), leaving `EshCore` guard-free and dependency-light. This is now a low-risk mechanical move because the boundary is already compiler-enforced by the guards.

## M1.7 API compatibility

- **No public API removed or renamed.** `InferenceBackendRegistry()` still exists on all platforms (its behavior is now platform-correct). `JSONValue`, `ContextPlanningBrief`, `VideoMetadata`, `ImageUpscaleBenchmarkStore`, etc. keep their names and public surface — only their defining file changed (same module, so no import churn for callers).
- One internal helper moved namespace: `VideoUnderstandingProvider.stringOption` → `CapabilityRequestOptions.string`, and `VisionUnderstandProvider.materialize/ext/stripDataURLPrefix` → `AttachmentIO.*`. These were **not** `public` API in practice (provider-internal statics); all in-repo call sites (incl. tests) were repointed.
- New public types added (`AttachmentIO`, `CapabilityRequestOptions`) — additive only.

## M1.8 Is `EshCore` now a suitable portable basis for `EshRuntime` (M3)?

**Yes.** On iOS, `EshCore` exposes the portable contracts (`InferenceBackend`, `BackendRuntime`, `ChatSession`, `GenerationConfig`, `ModelSpec`/`ModelInstall`, `CapabilityRequest`), the router/scheduler/Model-Fit logic, the DI `InferenceBackendRegistry` (Apple-only assembly), `AppleBackend`/`AppleBackendRuntime`, and `AppleIntelligenceService` with correct iOS availability and typed unavailable status. That is exactly the surface `EshRuntime` needs to reuse existing routing/scheduling over the Apple backend — no second model-selection architecture required.

