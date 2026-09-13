# esh SDK — Public API Contract (M10)

The **SDK surface** an app depends on is the public API of two products:

- **`EshRuntime`** — the app-facing facade + model management + request/result types (pulls `EshCore`).
- **`EshLlamaCpp`** — optional embedded GGUF backend + `EshRuntime.withEmbeddedGGUF()` convenience.

`EshCore` is also public, but as **advanced/SPI** — its large surface (engine, routing, capabilities,
persistence internals) is *not* part of the stable SDK contract. Apps should prefer `EshRuntime`.

Stability tiers: **STABLE** (semver-guarded; breaking change ⇒ major bump), **EXPERIMENTAL** (may change in
a minor; for advanced hosts/tests), **SPI** (public for composition but not part of the app contract).

## STABLE — the 1.0 candidate surface

### Entry points
| Symbol | Notes |
|---|---|
| `EshRuntime()` | Apple-first assembly (Apple FM on device). |
| `EshRuntime.withEmbeddedGGUF(config:root:)` | Apple FM + in-process GGUF (from `EshLlamaCpp`). |
| `runtime.generate(prompt:)` / `generate(_ request:)` | one-shot generation. |
| `runtime.stream(_:)` | `AsyncThrowingStream<EshGenerationEvent, Error>`. |
| `runtime.capabilities()` | `EshCapabilitySnapshot`. |
| `runtime.deviceProfile()` | `DeviceProfile`. |
| `runtime.localModels()` / `installPlan(for:)` / `install(_:onProgress:)` / `remove(_:)` / `reconcileLocalModels()` | model management. |

### Request / result / capability types
`EshConstraints` (`.auto`/`.localOnly`/`.pinned(_:)`), `EshGenerationRequest`, `EshGenerationResult`,
`EshGenerationEvent`, `EshSelection`, `EshCapabilitySnapshot`, `EshBackendAvailability`, `EshRuntimeError`.

### Model management types
`LocalModelDescriptor` (+ `.qwen05B` / `.qwen15B`), `LocalModelCatalog`, `LocalModelState`,
`LocalModelStatus`, `LocalModelInstallPlan`, `LocalModelError`, `LocalModelManager.ReconcileReport`.

### Embedded GGUF (product `EshLlamaCpp`)
`LlamaCppConfig`, `LlamaCppEmbeddedBackend`, `LlamaCppError`, `EshRuntime.withEmbeddedGGUF(...)`.

### Re-exported EshCore value types (STABLE as used by the facade)
`BackendKind`, `Message`, `GenerationConfig`, `Metrics`, `ModelInstall`, `ModelSpec`, `DeviceProfile`,
`AppleIntelligenceStatus`, `BackendCapabilityReport`, `PersistenceRoot`. These appear in `EshRuntime`
signatures, so their shape is part of the contract.

## EXPERIMENTAL

| Symbol | Why |
|---|---|
| `EshInstallProviding`, `FileInstallProvider`, `StaticInstallProvider` | DI seam for advanced hosts/tests; shape may change. |
| `EshRuntime.init(registry:installProvider:deviceProfileProvider:localModelManager:)` | DI init; advanced composition. |
| `LlamaCppEmbeddedRuntime`, `LlamaCppEmbeddedBackend.defaultResolveModelPath` | backend internals exposed for custom wiring. |
| `InferenceBackend` / `BackendRuntime` conformances | implementing a custom backend is advanced/unstable. |

## SPI (public, not the app contract)

All other `EshCore` public symbols (routing, scheduler, capability registry, `InferenceBackendRegistry`,
model-fit, persistence stores, HTTP/agent/context services in `EshMacRuntime`). Use at your own
compatibility risk; not covered by the SDK’s semver promise.

## Reductions applied in M10

- `DownloadOutcome` (downloader result) → **internal**. It was accidentally public and had no external
  consumer; it is an implementation detail of `ResumableDownloader` (already internal).

## Intentional behavior contract

- **Auto is Apple-first** on every platform. A downloaded GGUF never makes Auto select it.
- **A pin is never substituted.** A pinned model that is missing/not-ready fails with a typed
  `EshRuntimeError` — never a silent fallback to Apple.
- **`localOnly` has no hidden cloud fallback.** esh ships no remote backend.
- **Errors are typed.** Every production-relevant failure surfaces as `EshRuntimeError` /
  `LocalModelError` (or `CancellationError`); hosts never parse strings to branch.

## Versioning recommendation

Freeze the STABLE surface above as **`1.0.0-rc.1`** (see docs/PRODUCTION_READINESS.md for the RC verdict
and remaining pre-GA items). EXPERIMENTAL/SPI symbols are explicitly excluded from the 1.0 promise so the
internal engine can keep evolving. The first change that alters a STABLE signature is a `2.0`.
