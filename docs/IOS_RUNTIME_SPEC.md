# esh — iOS / Apple Platform Runtime SDK Specification

**Status:** Proposed implementation spec  
**Target:** Post-2.1 additive platform milestone  
**Repository:** `fil-technology/esh`  
**Primary goal:** Make esh usable as an embedded Swift runtime on iOS without weakening or rewriting the stable macOS runtime.

---

## 1. Executive Summary

esh is currently a macOS-focused local intelligence runtime built around reusable Swift abstractions (`EshCore`) plus macOS-specific execution paths such as Python/MLX workers, `llama-server`, subprocess management, CLI commands, and process inspection.

This milestone extends esh from:

> a macOS local-model runtime and CLI

into:

> a reusable local-intelligence runtime SDK for Apple platforms, beginning with iOS.

The implementation must **not** attempt to run the current macOS CLI/runtime unchanged on iOS.

Instead, esh will:

1. preserve a portable core of model, capability, routing, scheduling, session, and runtime contracts;
2. isolate macOS-only subprocess/runtime infrastructure;
3. add an embedded iOS-compatible runtime surface;
4. initially support Apple Foundation Models on eligible devices;
5. establish the backend boundary required for future embedded GGUF / llama.cpp inference;
6. expose a small developer-facing Swift API suitable for use by first-party and third-party iOS apps.

The macOS CLI remains a consumer of esh. iOS apps become another consumer.

---

# 2. Product Boundary

## 2.1 esh responsibility

esh owns:

- model execution;
- model/provider abstraction;
- capability discovery;
- local-vs-provider availability;
- routing among compatible intelligence backends;
- model fit / device fit;
- runtime lifecycle;
- model installation/storage abstractions where applicable;
- generation sessions/configuration;
- inference metrics;
- safe backend fallback policy;
- reusable Swift API for intelligence capabilities.

## 2.2 esh does NOT own

esh must not grow into:

- an autonomous user agent;
- goals;
- general planning;
- arbitrary tool-use loops;
- durable task orchestration;
- permissions for arbitrary real-world actions;
- long-running autonomous task state.

Those belong to **Ashex**.

Canonical boundary:

```text
Ashex
= agent / orchestrator
= goals
= planning
= tools
= observations
= iterative execution
= task state
= permissions
= actions
= durable work

            ↓ uses

esh
= local intelligence runtime
= model/provider execution
= routing
= Model Fit
= scheduler
= model lifecycle
= text / vision / speech / image capabilities
= Apple / MLX / GGUF / future runtimes
```

This iOS work must preserve that boundary.

---

# 3. Current State

The current Swift package exposes:

```text
EshCore      library
esh          executable
```

The package currently declares macOS only:

```swift
platforms: [
    .macOS(.v14)
]
```

`EshCore` contains both portable abstractions and platform-specific implementations.

Examples of macOS-specific behavior currently found within or below `EshCore` include:

- `Foundation.Process`;
- `/bin/ps`;
- Python execution;
- MLX bridge workers;
- persistent child processes;
- `llama-server`;
- process pipes;
- executable discovery;
- host process-tree memory inspection.

These mechanisms are valid on macOS and must remain available there, but they cannot form the iOS runtime implementation.

Existing architecture that should be preserved includes:

- `InferenceBackend`;
- `BackendRuntime`;
- `BackendCapabilityReport`;
- `ChatSession`;
- `GenerationConfig`;
- `ModelSpec`;
- `ModelInstall`;
- `CapabilityRequest`;
- scheduler/router concepts;
- Apple Foundation Models backend;
- typed capability system.

This existing backend/runtime separation is the foundation of the iOS work.

---

# 4. Core Design Principle

## 4.1 Do not port execution mechanisms; port contracts

Incorrect approach:

```text
iOS app
  ↓
esh CLI
  ↓
Process
  ↓
Python
  ↓
MLX
```

Correct approach:

```text
iOS app
  ↓
esh Swift SDK
  ↓
esh routing / scheduling / lifecycle
  ↓
iOS-compatible InferenceBackend
  ↓
native embedded runtime
```

The upper layers should remain unaware of whether inference comes from:

- Apple Foundation Models;
- an embedded GGUF runtime;
- a future native Apple runtime;
- a remote provider if explicitly allowed.

---

# 5. Target Architecture

## 5.1 Logical structure

```text
                         Esh Runtime
                             │
                ┌────────────┴────────────┐
                │                         │
             EshCore                 Runtime Facade
                │                         │
      portable contracts         easy public Swift API
                │                         │
       ┌────────┴────────┐       ┌────────┴────────┐
       │                 │       │                 │
 EshMacRuntime      EshAppleRuntime          future providers
       │                 │
       │                 ├─ Apple Foundation Models
       │                 ├─ embedded model runtime
       │                 └─ iOS device/model fit
       │
       ├─ MLX Python worker
       ├─ llama-server
       ├─ process runner
       └─ macOS host utilities
```

This is a logical architecture. Exact SwiftPM target names may differ if the coding audit finds a smaller migration path.

---

# 6. Proposed SwiftPM Products / Targets

The preferred end-state is:

```swift
products: [
    .library(name: "EshCore", targets: ["EshCore"]),
    .library(name: "EshRuntime", targets: ["EshRuntime"]),
    .executable(name: "esh", targets: ["esh"])
]
```

Potential targets:

```text
EshCore
EshRuntime
EshAppleRuntime
EshMacRuntime
esh
```

However, **do not create target fragmentation only for aesthetics**.

The coding agent must first perform a portability audit and choose the smallest structure that achieves:

1. `EshCore` builds for iOS;
2. macOS behavior remains intact;
3. platform-specific code does not leak into portable targets.

If a simpler first milestone uses conditional compilation before extracting final targets, that is acceptable if the boundaries remain explicit and testable.

---

# 7. Platform Requirements

Initial platform targets:

```text
macOS: preserve current supported baseline
iOS:   minimum version chosen based on required APIs
```

The coding agent must derive the exact minimum iOS deployment target from real dependencies and Apple Foundation Models availability rather than guessing.

No dependency may force the portable core to require a platform it does not intrinsically need.

---

# 8. Public SDK Goal

The final SDK should make common usage dramatically simpler than directly constructing individual backends.

Illustrative API:

```swift
import EshRuntime

let runtime = EshRuntime()

let response = try await runtime.generate(
    prompt: "Explain quantum tunnelling simply."
)
```

A richer request should be possible:

```swift
let result = try await runtime.generate(
    EshGenerationRequest(
        messages: [
            .user("Explain this in one paragraph.")
        ],
        constraints: .init(
            localOnly: true
        )
    )
)
```

And capability inspection:

```swift
let capabilities = await runtime.capabilities()
```

Potential future API:

```swift
let decision = await runtime.bestRuntime(
    for: .textGeneration,
    constraints: .localOnly
)
```

The public SDK should not force application developers to understand:

- MLX;
- llama.cpp;
- model file layout;
- process management;
- Apple FM availability internals;
- scheduler implementation.

---

# 9. Public API Principles

The SDK surface must be:

- Swift-native;
- async/await-native;
- `Sendable` where appropriate;
- safe under Swift 6 concurrency;
- platform-neutral at the request/result level;
- explicit about local-only guarantees;
- explicit about backend choice when requested;
- inspectable / explainable when Auto routing chooses a backend.

Avoid exposing backend implementation details unless the caller deliberately asks for them.

---

# 10. Phase 0 — Portability Audit

Before changing package structure, produce a repository portability audit.

Create:

```text
docs/IOS_PORTABILITY_AUDIT.md
```

For every source area, classify it as:

```text
PORTABLE
APPLE-SHARED
MACOS-ONLY
IOS-IMPLEMENTATION-NEEDED
UNKNOWN
```

At minimum audit:

```text
Sources/EshCore/
Sources/esh/
Package.swift
Package.resolved
```

Specifically search for:

- `Process`;
- `Pipe`;
- shell paths;
- `/bin/*`;
- `/usr/bin/*`;
- Python;
- localhost worker assumptions;
- process PID / RSS inspection;
- AppKit;
- macOS-only APIs;
- `#available(macOS ...)`;
- dependencies with macOS-only package manifests;
- file-system assumptions;
- external executable assumptions.

### Exit criterion

We know exactly which files prevent `EshCore` from compiling for iOS and what boundary each should move behind.

No behavior changes are required in Phase 0.

---

# 11. Phase 1 — Make the Core Platform-Portable

Goal:

> An iOS target can import and compile the portable esh runtime contracts.

### Required outcomes

- Add iOS to the package platform declaration.
- Remove or isolate macOS-only APIs from portable build paths.
- Preserve the current public model/session/backend contracts unless a change is truly necessary.
- Preserve current macOS behavior.
- Keep source compatibility where practical.

### Preferred techniques

Use, in priority order:

1. proper protocol/injection boundary;
2. platform-specific implementation target;
3. conditional compilation for small platform-specific pieces.

Avoid large forests of:

```swift
#if os(macOS)
...
#elseif os(iOS)
...
#endif
```

inside core business logic.

### Exit criterion

A minimal iOS test target can:

```swift
import EshCore
```

and compile successfully.

All existing macOS tests remain green.

---

# 12. Phase 2 — Apple Foundation Models on iOS

The Apple backend is the first real inference backend for iOS.

Existing code already includes:

```text
AppleProvider
AppleBackend
AppleBackendRuntime
AppleIntelligenceService
```

Current availability logic is macOS-specific.

### Required work

- make Apple FM platform availability checks correct for iOS and macOS;
- keep compile-time guards using `canImport(FoundationModels)`;
- keep runtime availability explicit;
- preserve the rule that Apple FM does not silently replace an explicitly pinned downloaded model;
- preserve strict local/on-device semantics where the API actually guarantees them;
- expose availability/status through the shared capability surface;
- ensure unsupported devices fail with a typed, actionable error.

### Important

Do not duplicate the Apple provider implementation into separate macOS and iOS copies unless the API genuinely requires divergent implementations.

Prefer a shared Apple-platform implementation.

### Exit criterion

A small iOS sample/test harness can:

1. create the esh runtime;
2. inspect Apple provider availability;
3. issue a text generation request when available;
4. receive an esh generation result;
5. identify which backend handled the request.

---

# 13. Phase 3 — Introduce `EshRuntime` Facade

`EshCore` should remain low-level.

Create a higher-level application-facing runtime facade.

Illustrative shape:

```swift
public actor EshRuntime {
    public init(configuration: EshRuntimeConfiguration = .default)

    public func capabilities() async -> EshCapabilitySnapshot

    public func generate(
        _ request: EshGenerationRequest
    ) async throws -> EshGenerationResult

    public func stream(
        _ request: EshGenerationRequest
    ) -> AsyncThrowingStream<EshGenerationEvent, Error>
}
```

Exact names may change to align with existing types.

### Requirements

The facade must:

- reuse existing scheduler/router/runtime lifecycle code;
- not create a parallel model-selection architecture;
- allow dependency injection for tests;
- support explicit backend/model pinning;
- support automatic selection;
- surface the final selected backend/model;
- make local-only policy enforceable;
- remain suitable for macOS clients too.

### Exit criterion

A developer does not need to instantiate `AppleBackend`, scheduler internals, model stores, etc. for basic inference.

---

# 14. Phase 4 — iOS Device Profile and Model Fit

Create a platform-neutral host/device capability model.

Do not reuse macOS process/RSS inspection as the abstraction itself.

Example concept:

```swift
public struct DeviceProfile: Sendable {
    public let platform: Platform
    public let physicalMemoryBytes: UInt64
    public let availableStorageBytes: UInt64?
    public let thermalState: ThermalState?
    public let lowPowerModeEnabled: Bool?
    public let supportsAppleFoundationModels: Bool
}
```

The exact fields should be derived from what esh Model Fit truly needs.

### iOS inputs may include

- physical memory where available;
- free storage;
- device family/model identifier if useful;
- thermal state;
- low-power mode;
- OS version;
- available backend capabilities.

### Rules

- never pretend memory availability is more precise than iOS actually exposes;
- distinguish measured values from estimates;
- Model Fit recommendations must explain their evidence;
- runtime should be conservative under thermal/memory pressure.

### Exit criterion

esh can produce an iOS-relevant device/profile report and use it in routing / fit decisions without depending on macOS process inspection.

---

# 15. Phase 5 — Embedded GGUF Backend

This is **not required for the first iOS compile milestone**, but the architecture must leave a clear slot for it.

The current macOS GGUF implementation uses a spawned llama server. That must remain a macOS implementation.

iOS requires an in-process backend:

```text
LlamaCppEmbeddedBackend
        ↓
native llama.cpp library / Swift binding
        ↓
GGUF
        ↓
Metal / native acceleration
```

### Required design properties

- implement the existing `InferenceBackend` / `BackendRuntime` contract;
- no subprocess;
- no local HTTP server;
- no shell;
- no Python;
- model lifetime controlled by esh;
- stream tokens through the common streaming abstraction;
- expose memory/fit requirements where measurable;
- allow runtime unload under memory pressure.

### Dependency rule

Do not add llama.cpp to the main package until:

1. the binding/package is evaluated for maintenance quality;
2. iOS simulator/device builds are verified;
3. license implications are recorded;
4. binary size implications are measured.

### Deliverable before implementation

Create:

```text
docs/IOS_EMBEDDED_GGUF_EVALUATION.md
```

comparing realistic integration options.

---

# 16. Model Storage on iOS

The existing macOS external-volume model layout must not simply be copied.

iOS model storage should use app-controlled storage.

Required abstractions:

```text
ModelStorage
ModelDownload
ModelInstall
ModelRemoval
StorageCapacity
```

The exact existing APIs should be reused when they are already sufficiently abstract.

### iOS behavior

- models downloaded only after explicit user/app intent;
- resumable download where feasible;
- verify model integrity;
- report required download size before starting;
- verify free disk space;
- no invisible giant downloads;
- support deletion/unload cleanly;
- app sandbox only.

External SSD semantics remain macOS-specific.

---

# 17. Runtime Lifecycle on iOS

The existing concept of persistent residency should remain, but implementation semantics differ.

iOS cannot promise indefinite resident processes.

The runtime should react to:

- app foreground/background transitions;
- memory warnings;
- thermal pressure;
- explicit unload request;
- model switching.

Potential policy:

```text
foreground + healthy memory:
    keep active model warm

memory warning:
    release optional caches
    unload inactive runtimes

background:
    follow app/runtime policy
    never assume indefinite execution
```

The public contract must not promise macOS-style persistent residency on iOS.

---

# 18. Routing Rules

Existing routing semantics should remain authoritative.

Important invariant:

> Platform availability constrains routing; it must not fork routing logic into an unrelated iOS router.

Example:

```text
Request
  ↓
Capability Request
  ↓
Registry
  ↓
Available providers on this device
  ↓
Scheduler / Model Fit
  ↓
Execution plan
```

On iOS, candidate providers may initially be:

```text
Apple Foundation Models
```

Later:

```text
Apple Foundation Models
Embedded GGUF
other native providers
```

On macOS:

```text
Apple Foundation Models
MLX
GGUF server/runtime
...
```

The capability router remains one conceptual system.

---

# 19. Local-Only Semantics

`localOnly` must be a hard constraint, not a preference.

If a request says:

```text
localOnly = true
```

then a backend that may execute remotely must not be selected unless its semantics are explicitly compatible with that contract.

If no compatible backend exists:

```text
fail explicitly
```

Do not silently fall back to cloud.

This requirement applies equally on macOS and iOS.

---

# 20. Backend Selection / Explainability

Automatic routing should make the final decision inspectable.

Result metadata should be able to answer:

```text
provider: apple-foundation
model: apple-intelligence
reason: no-download on-device provider available
constraints satisfied:
  localOnly: true
  capability: text.generate
```

For future downloadable models:

```text
provider: llama.cpp-embedded
model: qwen-...
reason: user pinned model
```

This should reuse existing “Why this model?” / scheduler concepts rather than creating a second explanation model.

---

# 21. Concurrency

All new SDK APIs must obey Swift 6 strict concurrency.

Requirements:

- no unsafe shared mutable runtime state;
- model lifecycle serialized where required;
- generation cancellation supported;
- streaming cancellation propagates to backend;
- no detached process assumptions on iOS;
- backend runtime types reviewed for `Sendable` correctness.

Do not silence concurrency warnings with `@unchecked Sendable` unless justified and documented.

---

# 22. Cancellation

A caller must be able to cancel generation.

For:

```swift
let task = Task {
    try await runtime.generate(...)
}

task.cancel()
```

the runtime should stop inference as soon as the underlying backend permits.

Streaming cancellation must release generation resources.

This matters significantly on battery-powered mobile devices.

---

# 23. Memory Pressure

Create a platform abstraction for runtime pressure signals.

Concept:

```swift
protocol RuntimePressureSource {
    var events: AsyncStream<RuntimePressureEvent> { get }
}
```

Possible events:

```text
memoryWarning
thermalNominal
thermalSerious
thermalCritical
lowPowerModeChanged
```

Policy belongs to runtime lifecycle / scheduler logic, not view code.

---

# 24. Sample Application

Add a minimal example application or isolated example project after the core builds on iOS.

Suggested:

```text
Examples/EshIOSDemo/
```

The demo should intentionally be small.

Features:

- show runtime capabilities;
- show Apple FM status;
- basic text prompt;
- stream or display result;
- show chosen backend;
- show reason/diagnostics;
- cancellation button.

It must not become a product UI project.

Its purpose is integration validation.

---

# 25. Tests

## 25.1 Portable core tests

Existing core tests should run on macOS.

Add tests for:

- platform-neutral generation requests;
- scheduler filtering by backend availability;
- local-only guarantees;
- pinned-provider behavior;
- capability snapshots;
- runtime facade behavior with mocked backends.

## 25.2 iOS-compatible tests

At minimum build/test:

- portable core for iOS simulator;
- runtime facade for iOS simulator;
- Apple provider compile path.

Live Apple FM inference tests may require physical supported devices and should be separated from deterministic CI.

## 25.3 Regression

Zero accepted regressions in:

- current macOS CLI;
- MLX inference;
- GGUF inference;
- routing;
- scheduler;
- API surfaces;
- existing test suite.

---

# 26. CI

Extend CI to include an iOS compilation gate.

At minimum:

```text
macOS Swift tests
iOS simulator build for portable/runtime targets
```

Do not require live model downloads or live Apple FM availability in ordinary CI.

A separate manual/device validation workflow can be introduced later.

---

# 27. Documentation

Required docs:

```text
docs/IOS_RUNTIME_SPEC.md
docs/IOS_PORTABILITY_AUDIT.md
docs/IOS_EMBEDDED_GGUF_EVALUATION.md        # before Phase 5
```

Later, when the SDK is usable:

```text
docs/SDK.md
Examples/EshIOSDemo/
```

README should only be changed when there is actual supported iOS functionality.

Do not advertise iOS support just because a target compiles.

---

# 28. Versioning

This change should remain additive.

Do not unnecessarily break the stable macOS command/API contract.

The coding agent should inspect the current semver/API contract documents before changing public interfaces.

Any unavoidable breaking public API change must be:

- explicitly identified;
- justified;
- migrated deliberately;
- tested.

---

# 29. Dependencies

Before introducing any new dependency:

1. verify iOS support;
2. verify Swift 6 compatibility;
3. verify license;
4. verify binary size;
5. verify maintenance activity;
6. verify simulator + device build behavior;
7. document why the dependency belongs inside esh.

Avoid adding a dependency only to reduce a small amount of straightforward Swift code.

---

# 30. Security / Privacy

The iOS SDK inherits esh’s local-first promise.

Required properties:

- no telemetry by default;
- no hidden cloud fallback;
- no uploading prompts without an explicitly selected provider/policy;
- model downloads only from explicit trusted sources;
- verify downloaded model identity/integrity where possible;
- expose what backend actually executed a request.

---

# 31. Non-Goals for Initial Milestone

Do not implement all of these in the first PR:

- full GGUF runtime;
- MLX Python on iOS;
- arbitrary Python execution;
- CLI on iOS;
- `esh serve` on iOS;
- background local HTTP server;
- full voice stack;
- image generation;
- vision;
- complete model marketplace;
- Ashex agent logic;
- full public commercial SDK packaging;
- XCFramework distribution.

The first milestone is architecture + compile + one real native backend.

---

# 32. Initial Milestone — iOS Runtime Foundation

## Goal

Prove that esh can operate as an embedded iOS intelligence runtime without compromising the macOS product.

## Deliverables

### A. Audit

```text
docs/IOS_PORTABILITY_AUDIT.md
```

### B. Package portability

- iOS platform declared;
- portable core builds for iOS;
- macOS-only runtime code isolated.

### C. Apple backend

- Apple Foundation Models implementation shared across supported Apple platforms;
- correct iOS availability checks;
- typed availability failures;
- capability reporting.

### D. Runtime facade

Minimal usable API:

```swift
EshRuntime
capabilities()
generate(...)
```

or an equivalent API built cleanly from existing types.

### E. Tests

- macOS tests green;
- iOS simulator build green;
- routing/local-only/pinning tests.

### F. Demo / validation

A minimal iOS integration target proves:

```text
App → EshRuntime → Router/Scheduler → AppleBackend → result
```

No direct Apple FM call from the demo except through esh.

---

# 33. Acceptance Criteria for Initial Milestone

The milestone is complete only when all are true:

- [ ] `EshCore` or its portable successor compiles for iOS.
- [ ] macOS-only subprocess code is not reachable in an iOS build.
- [ ] no Python runtime is required on iOS.
- [ ] no child process is required on iOS.
- [ ] no localhost model server is required on iOS.
- [ ] Apple Foundation Models can be represented as an esh backend on iOS.
- [ ] unsupported Apple FM devices return an honest typed availability result.
- [ ] `localOnly` remains enforceable.
- [ ] explicit model/provider pinning is respected.
- [ ] Auto uses the existing scheduler/router concepts.
- [ ] a caller can invoke inference through an esh SDK facade.
- [ ] selected backend metadata is observable.
- [ ] cancellation works through the public API.
- [ ] existing macOS tests pass.
- [ ] an iOS simulator build is part of verification.
- [ ] README does not overclaim unsupported features.
- [ ] Ashex responsibilities were not moved into esh.

---

# 34. Suggested Implementation Order

```text
0. Read source of truth / architecture
1. Portability audit
2. Compile-only iOS support for portable core
3. Isolate macOS runtime dependencies
4. Cross-platform Apple Foundation Models backend
5. EshRuntime facade
6. iOS simulator test target
7. Minimal iOS demo
8. Device-profile / mobile Model Fit foundation
9. Embedded GGUF evaluation
10. Embedded GGUF implementation in a later milestone
```

Do not start at step 9.

---

# 35. Architecture Decision Rules

When implementation choices conflict, use these priorities:

1. preserve correctness and honest capability reporting;
2. preserve stable macOS behavior;
3. maintain one conceptual router/scheduler architecture;
4. keep platform-specific execution behind backend/runtime boundaries;
5. keep the iOS public API simple;
6. minimize duplicated code;
7. prefer protocols/dependency injection over platform conditionals in business logic;
8. do not prematurely package binaries/XCFrameworks;
9. do not expand esh into Ashex responsibilities.

---

# 36. Definition of Success

Success is not:

> “the esh CLI somehow launches on an iPhone.”

Success is:

> “Any Swift iOS app can embed esh, ask for an intelligence capability, and let esh safely choose and execute the best compatible local backend for that device.”

The long-term result should look like:

```text
                 ┌─────────────────┐
                 │     Ashex       │
                 └────────┬────────┘
                          │
                    uses intelligence
                          │
                 ┌────────▼────────┐
                 │       esh       │
                 │ Runtime / SDK   │
                 └────────┬────────┘
                          │
         ┌────────────────┼────────────────┐
         │                │                │
       macOS             iOS          future Apple
         │                │              platforms
   MLX / GGUF /      Apple FM /
   Apple FM          embedded models
```

esh becomes the reusable runtime.

Ashex remains the agent.
