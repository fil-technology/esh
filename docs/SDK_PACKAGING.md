# esh — SDK Slimming & Runtime Packaging (M9)

Cleanly separates the **portable SDK/runtime** from **macOS-only execution infrastructure**, so an iOS app
links a small, dependency-light SDK and the macOS CLI keeps its full backend assembly. No product UI, no
Auto-policy change (both out of M9 scope).

## Target graph (after M9)

```
                 ┌─────────────┐
                 │   EshCore   │  portable contracts / domain / routing / model-fit /
                 │ (no deps)   │  persistence / download / device profile / Apple FM backend
                 └──────┬──────┘
        ┌───────────────┼───────────────┬────────────────────┐
        │               │               │                    │
 ┌──────▼─────┐  ┌──────▼──────┐  ┌─────▼────────┐   ┌────────▼────────┐
 │ EshRuntime │  │ EshLlamaCpp │  │ EshMacRuntime│   │  (iOS app)      │
 │ facade     │  │ +CLlama     │  │ +swift-syntax│   │ EshRuntime      │
 │ →EshCore   │  │ (optional,  │  │ macOS-only   │   │ (+EshLlamaCpp)  │
 └────────────┘  │  embedded   │  │ execution    │   └─────────────────┘
                 │  GGUF)      │  └──────┬───────┘
                 └─────────────┘         │
                                  ┌──────▼──────┐
                                  │     esh     │  macOS CLI
                                  │ →EshCore    │
                                  │ →EshMacRuntime
                                  │ →TTSMLX     │
                                  └─────────────┘
```

Measured per-target dependencies (`swift package describe`):

| Target | Kind | Depends on | External products |
|---|---|---|---|
| **EshCore** | library | — | **none** |
| **EshRuntime** | library | EshCore | none |
| **EshLlamaCpp** | library (optional) | EshCore, CLlama | none |
| **EshMacRuntime** | library (macOS) | EshCore | **SwiftParser, SwiftSyntax** |
| **esh** | executable (macOS) | EshCore, EshMacRuntime | TTSMLX |

`EshLlamaCpp` + `CLlama` are included only when `Vendor/llama.xcframework` is present (built by
`scripts/build-llama-xcframework.sh`; not committed).

## What moved, and why

M8 left ~49 whole-file `#if os(macOS)` implementations plus the swift-syntax symbol extractor inside the
portable core. M9 moves the macOS execution infrastructure into a dedicated **`EshMacRuntime`** target:

- **MLX** runtime/bridge/worker/persistent-runtime/locator/backend, MLX Python-bridge doctor.
- **Spawned GGUF** (`llama-server`) backend, server runtime, aux/server processes.
- **Speech** worker + runtime manager; **capability providers** that shell out to the optional
  generative-engine runtime (image gen/edit/upscale, segmentation, audio-gen/diarization, video/vision
  understanding, embeddings).
- **Local HTTP servers** and **compat services** (OpenAI/Anthropic), agent/context services
  (`AgentLoopService`, `ContextStore`, `ContextQueryEngine`, `ContextPackageService`, …), doctor/onboarding/
  orchestrator/validation services.
- **TurboQuant** bridge + compressor.
- **`SymbolExtractor`** (swift-syntax) and **`ContextIndexer`** (its only in-core consumer, used by the
  macOS `esh context` command).

Result: **EshCore has 0 whole-file `#if os(macOS)` guards** (was 49) — only **6 files** keep small
*surgical* platform diffs (see below).

## swift-syntax removed from the portable core

`SymbolExtractor` was EshCore's only swift-syntax consumer. It moved to EshMacRuntime, and the swift-syntax
package dependency moved with it. **EshCore no longer depends on SwiftSyntax/SwiftParser.**

Proven for the iOS build:
- The iOS build graph compiles **0** SwiftSyntax/SwiftParser modules (xcodebuild for `iOS Simulator`).
- The built iOS app binary contains **0** SwiftSyntax/SwiftParser symbols (`nm`/`strings`).

## Preserving platform assembly (no scheduler/router duplication)

The portable `InferenceBackendRegistry` still holds *injected* backends and references no concrete backend
type. Its default `init()` now wires **Apple Foundation Models only** (portable, every Apple platform). The
macOS execution assembly lives in EshMacRuntime as **`InferenceBackendRegistry.macOS()`** (MLX + spawned
GGUF + Apple); the `esh` CLI injects it. The router, scheduler, model-fit, and facade are untouched and
un-duplicated — only *where the concrete backends are constructed* changed.

Two portable code paths defer to macOS behavior through **set-once hooks** in EshCore, filled by
`EshMacRuntime.MacRuntimeBootstrap.install()` (called once at `esh` startup; never on iOS):

| Hook (EshCore) | macOS implementation (EshMacRuntime) | iOS / unset fallback |
|---|---|---|
| `RoutingEngineProbe.isInstalled` | `GenerativeEngineManager(root:).isInstalled(…)` | engines report "not installed" |
| `CacheArtifactSupport.turboCompressorFactory` | `TurboQuantCompressor()` | passthrough compressor |

These replace the two unguardable EshCore→macOS references; both are `nonisolated(unsafe)` statics set once
before concurrency begins.

## Surgical platform diffs kept in EshCore (6 files)

Not every platform difference is worth a separate target. These stay portable with small `#if os(macOS)`
diffs (behavior identical to before; absent from the iOS binary):

- `ExecutablePath.swift` — `_NSGetExecutablePath` on macOS; `argv[0]` fallback elsewhere.
- `Utils/SystemProcesses.swift` — `/bin/ps` memory-hog probe (macOS-only), enriches a portable low-memory
  message; whole file is `#if os(macOS)`, so no `Process` reaches iOS.
- `Utils/SystemMemory.swift` — honest available-memory (`os_proc_available_memory` on iOS vs `vm_stat`/host
  stats on macOS).
- `Persistence/PersistenceRoot.swift` — app-container root on iOS vs home dir on macOS.
- `Services/DeviceProfileProvider.swift` — iOS/macOS device-profile signal sources.
- `Services/ExternalInferenceService.swift` — the MLX-only prompt-cache-artifact load path (macOS), now via
  the `CacheArtifactSupport` hook.

## Public API

Preserved. `EshRuntime` (facade), `EshCore` value types, and `EshLlamaCpp` are unchanged for app consumers.
The one intentional behavior refinement: `EshRuntime()` / `InferenceBackendRegistry()` defaults are now
**Apple-first on every platform** (macOS execution backends are host-injected via `EshMacRuntime`, exactly as
the embedded GGUF backend has always been app-injected). No repo code relied on the old macOS default; all
`EshRuntimeTests` inject backends explicitly. This matches the M-series constraint that Auto stays Apple-first
and pinned GGUF never silently falls back.

## Distribution shape

- **iOS / app SDK:** depend on `EshRuntime` (pulls `EshCore`). Optionally add `EshLlamaCpp` (embedded GGUF)
  when `Vendor/llama.xcframework` is vendored; the app injects that backend. No swift-syntax, no MLX, no TTS,
  no `EshMacRuntime`, no `Process` in the graph.
- **macOS CLI / server:** the `esh` executable depends on `EshCore` + `EshMacRuntime` (+ TTSMLX). It calls
  `MacRuntimeBootstrap.install()` and injects `InferenceBackendRegistry.macOS()`.
- **macOS embedders** who want only the portable SDK can depend on `EshRuntime` alone and inject their own
  backends.

## Size & scope metrics (measured)

| Target | Swift files | LOC |
|---|---|---|
| EshCore (portable) | 194 | 24,805 |
| EshRuntime (facade) | 4 | 779 |
| EshLlamaCpp (optional) | 1 | 323 |
| EshMacRuntime (macOS) | 52 | 10,799 |
| esh (macOS CLI) | 74 | 11,840 |

- EshCore whole-file `#if os(macOS)` guards: **49 → 0**; surgical `#if os(` diff files: **6**.

### iOS app binary size vs M8 baseline

Probe `.app`, `iOS Simulator`, **Release**, `CODE_SIGNING_ALLOWED=NO`, WITH embedded GGUF backend
(`EshRuntime` + `EshLlamaCpp`), built identically from the M8 commit (`8c2c4cf`) and the M9 tree:

| Build | `.app` | Main binary | swift-syntax symbols (`nm`) |
|---|---|---|---|
| **M8** (`8c2c4cf`, swift-syntax in EshCore) | **63 MB** | 47.0 MB (49,221,576 B) | **84,025** |
| **M9** (swift-syntax out of iOS graph) | **32 MB** | 16.3 MB (17,052,216 B) | **0** |
| **Delta** | **−30 MB** | **−31 MB** (−32,169,360 B) | **−84,025** |

Both built the same probe (`EshRuntime` + `EshLlamaCpp`) with the same `Vendor/llama.xcframework`, same
Release/simulator flags, so `llama.framework` is identical across the two and the entire delta is the
swift-syntax code no longer linked into the iOS product.

The GGUF model file is downloaded at runtime (not bundled), so `.app` size reflects code + embedded
`llama.framework` + Metal only. The reduction is the swift-syntax code removed from the iOS graph — M8's own
benchmark noted the without-GGUF app was "inflated by swift-syntax, which EshCore still links."

## Build / dependency effects

- **iOS build graph** no longer resolves-and-compiles swift-syntax (a large source dependency): `EshCore`
  and `EshRuntime` build for `iOS Simulator` with **0** SwiftSyntax/SwiftParser compilations.
- **macOS full build** (`swift build`) unchanged in composition; swift-syntax now compiles only as part of
  `EshMacRuntime`/`esh`, not as a dependency of the portable `EshCore` library that iOS apps consume.

## Regression proof

- **macOS unit tests: 649 / 649 pass** (`swift test`), unchanged from the M8 baseline. Tests were split to
  match the target boundary: macOS-only suites moved to `EshMacRuntimeTests`; portable suites stay in
  `EshCoreTests`; `EshRuntimeTests` / `EshUITests` unchanged in intent.
- **iOS Simulator build: `EshRuntime` (+`EshCore`) BUILD SUCCEEDED**, no swift-syntax / EshMacRuntime.
- **iOS device paths unchanged:** Apple FM inference, embedded GGUF inference, and app-managed model install
  (M4/M5/M7/M8) all run through the same `EshRuntime` facade and `EshLlamaCpp` backend, which M9 did not
  modify.

## Non-goals (unchanged)

No model-management UI, no App Store packaging design, no ChatGPT integration, no Auto GGUF preference, no
additional GGUF models, no cloud providers, no Ashex.
