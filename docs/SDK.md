# esh SDK — `EshRuntime`

`EshRuntime` is the small, app-facing Swift API for embedding esh's local intelligence runtime in an
iOS or macOS app. It lets an app request a capability and let esh select and execute the best compatible
**local** backend for the device — without the app constructing backends, registries, schedulers, or
runtimes.

```swift
import EshRuntime

let runtime = EshRuntime()
let result = try await runtime.generate(prompt: "Hello")
print(result.text)
```

- **iOS:** the default assembly currently exposes **Apple Foundation Models only**. There is no embedded
  GGUF/llama.cpp or native MLX backend on iOS yet — do not assume one.
- **macOS:** the existing MLX / GGUF / Apple backends remain available (unchanged).

Add the package and depend on the `EshRuntime` product:

```swift
.product(name: "EshRuntime", package: "esh")
```

## Capabilities

Inspect what the device can do before generating:

```swift
let snapshot = await runtime.capabilities()
snapshot.hasReadyBackend                     // is anything ready?
snapshot.appleIntelligence.availability      // .available / .deviceNotEligible / .appleIntelligenceNotEnabled / .modelNotReady / .unsupportedOS / .frameworkUnavailable / .unknown
for b in snapshot.backends {
    print(b.backend, b.report.ready, b.isLocal)
}
```

`AppleIntelligenceStatus` is honest and typed: on an unsupported/disabled device it reports the exact
reason (and a suggested fix) rather than pretending to be ready.

## Auto selection

With no pin, esh selects automatically: Apple Foundation Models first (zero-download, on-device), then any
installed model whose backend is wired on the platform. The chosen backend/model and the reason are
returned so the decision is inspectable:

```swift
let r = try await runtime.generate(prompt: "Summarize this…")
r.selection.backend     // e.g. .apple
r.selection.modelID     // e.g. "apple-intelligence"
r.selection.reason      // e.g. "no-download on-device provider available"
```

## Explicit pinning

Pin a specific provider/model. A pinned model is used exactly and is **never** silently substituted with
another provider; if it is not installed or its backend is not available on this platform, you get a typed
error instead:

```swift
// Pin Apple explicitly:
_ = try await runtime.generate(EshGenerationRequest(
    prompt: "…", constraints: .pinned(AppleProvider.canonicalModelID)))

// Pin a downloaded model (macOS):
_ = try await runtime.generate(EshGenerationRequest(
    prompt: "…", constraints: .pinned("my-downloaded-model-id")))
```

## `localOnly`

`localOnly` is a **hard constraint**, not a preference. esh ships no cloud/remote backend and never falls
back to the cloud, so local-only requests are honored by construction; a backend whose execution is not
local would be refused rather than used. It defaults to `true`.

```swift
let req = EshGenerationRequest(prompt: "…", constraints: .localOnly)   // == .init(localOnly: true)
let r = try await runtime.generate(req)
r.selection.localOnlySatisfied   // true
```

## Streaming

```swift
for try await event in runtime.stream(EshGenerationRequest(prompt: "…")) {
    switch event {
    case .token(let chunk): // incremental text
        print(chunk, terminator: "")
    case .completed(let result): // final assembled result + selection + metrics
        print("\n[", result.selection.backend, result.selection.modelID, "]")
    }
}
```

Backends that stream emit multiple `.token` events; Apple Foundation Models returns its response as a
single `.token` today, followed by `.completed`.

## Cancellation

Cancelling the surrounding task stops generation and releases the backend runtime. A cancelled generation
throws `CancellationError` rather than returning partial text:

```swift
let task = Task { try await runtime.generate(prompt: "…") }
task.cancel()
```

For `stream`, cancelling the consuming task terminates the stream and cancels the underlying generation.

## Result metadata

`EshGenerationResult` exposes:

- `text` — the generated text;
- `selection` — `backend`, `modelID`, `reason`, `localOnlySatisfied`;
- `metrics` — `EshCore.Metrics` (e.g. `ttftMilliseconds`, `finishReason`) as reported by the backend.

## Errors

`EshRuntimeError` is typed: `.noAvailableBackend`, `.pinnedModelUnavailable`, `.backendUnavailable`,
`.localOnlyViolation`. Apple-unavailable devices surface through `capabilities()` / the honest typed status.

## Testing / dependency injection

`EshRuntime(registry:installProvider:)` injects the backend assembly and installed-model source, so apps
and tests can run the full facade against mock backends with no Apple/MLX dependency. See
`Tests/EshRuntimeTests`.

## Current iOS limitation

Apple Foundation Models is presently the **only** default iOS inference backend. Embedded GGUF/llama.cpp and
native MLX on iOS are not implemented and are not advertised. Live on-device Apple FM inference is validated
manually via the `Examples/EshIOSProbe` app (SwiftPM package tests cannot run on a physical device); see
`docs/IOS_M2_DEVICE_VALIDATION.md`.
