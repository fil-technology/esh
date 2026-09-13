# esh SDK — Production Readiness (M10)

## Verdict: **READY for a first-party production Release Candidate — `1.0.0-rc.1`**

`EshRuntime` is safe to embed in a real first-party iOS app today: a fresh app integrates it via SwiftPM
and the public API alone (no internal coupling), Apple FM and managed embedded GGUF both work, the model
lifecycle survives interruption/restart, failures are typed, concurrency is defined, and the whole thing
builds from a clean checkout with no machine-local dependencies. It is tagged `1.0.0-rc.1` rather than a
final GA because a short, **non-code** list remains — resolve during the RC period before GA:

1. Add a top-level `LICENSE` (esh) + bundle the llama.cpp **MIT** notice.
2. Publish the pinned `llama.xcframework` release asset and set `llamaBinaryURL` (checksum already pinned).
3. Hardware-validate the device matrix below 8 GB (e.g. iPhone 12 Pro) and on iPad.
4. Re-run the on-device clean-room validation on the iPhone 17 (this session's live launch was blocked by
   the device being locked; the paths are unchanged and were proven live on that device in M4/M7/M8).

None of these block first-party embedding; they gate a public GA. No blockers to the RC.

---

How to embed the esh runtime in a production iOS app, and what it guarantees. Companion docs:
[SDK_API_CONTRACT.md](SDK_API_CONTRACT.md) (public surface + versioning), [SDK_PACKAGING.md](SDK_PACKAGING.md)
(targets, llama distribution, sizes).

## Supported platforms & minimum OS

| | Minimum | Notes |
|---|---|---|
| iOS / iPadOS | 17.0 (deployment floor) | Portable SDK builds down to iOS 17. |
| Apple Foundation Models | iOS **26.0**+, Apple-Intelligence-capable device | Runtime-gated (`#available`); unsupported hardware/OS reports unavailable, never crashes. |
| Embedded GGUF (`EshLlamaCpp`) | iOS 17.0+, arm64 device or simulator | In-process llama.cpp + Metal. |
| macOS | 14.0 | CLI + full backend assembly (`EshMacRuntime`). |

## Installation

Add the package and depend on the products you need:

```swift
.product(name: "EshRuntime",  package: "esh"),   // Apple Foundation Models — no extra setup
.product(name: "EshLlamaCpp", package: "esh"),   // optional: embedded GGUF (adds withEmbeddedGGUF)
```

`EshRuntime` alone pulls only `EshCore` (no third-party Swift packages, no llama.cpp). Adding
`EshLlamaCpp` links the pinned `llama.xcframework` (see SDK_PACKAGING.md §llama distribution — hosted
`binaryTarget(url:checksum:)` in production, local `Vendor/` build for development).

## Usage

**Apple Foundation Models (zero setup):**
```swift
import EshRuntime
let runtime = EshRuntime()
let result = try await runtime.generate(prompt: "Hello")     // Auto → Apple FM on device
```

**Managed embedded GGUF:**
```swift
import EshRuntime
import EshLlamaCpp
let runtime = EshRuntime.withEmbeddedGGUF()
await runtime.reconcileLocalModels()                          // repair interrupted state (call at launch)
try await runtime.install(.qwen05B) { progress in … }         // download → verify → record
let r = try await runtime.generate(.init(prompt: "…", constraints: .pinned("qwen2.5-0.5b-instruct-q4km")))
```

The host never constructs a registry or backend, never touches a model path, and never links llama.cpp
directly. Verified by the **clean-room integration test** (`Examples/EshCleanRoom`) — a fresh app that
consumes esh only through these public products, built outside the package tree.

## Error contract (#4)

Every production-relevant failure is typed. `EshRuntimeError`: `noAvailableBackend`,
`pinnedModelUnavailable`, `backendUnavailable`, `localOnlyViolation`, `unsupportedDevice`,
`modelLoadFailed`, `generationFailed`. `LocalModelError`: `unknownModel`, `insufficientStorage`,
`alreadyInstalled`, `notInstalled`, `contentLengthMismatch`, `checksumMismatch`, `downloadFailed`,
`installFileMissing`, `installInProgress`, `invalidModelID`, `insecureSource`. Cancellation surfaces as
Swift’s `CancellationError`. A host switches over these exhaustively; it never parses a string to branch.

## Concurrency guarantees (#9)

- `EshRuntime` is an `actor`; `LocalModelManager` is an `actor`. Swift 6 strict concurrency is clean.
- **Generation** is concurrency-safe: many `generate`/`stream` calls run concurrently; each cancels
  independently (cancelling the task stops the stream and releases the runtime). Verified with 50
  concurrent generations + generate-while-querying (no deadlock, no data race).
- **Install** is serialized per model id: a duplicate concurrent install fails fast with
  `installInProgress` (exactly one winner). Verified.
- `install`/`remove`/`generate` on different models are independent. A `generate` racing a `remove` of the
  same model fails typed (`modelLoadFailed`/`pinnedModelUnavailable`), never a crash.

## Model lifecycle & durability (#5)

- A model is **installed** only when its record **and** verified file both exist. A lone record or lone
  file is never reported usable.
- Integrity is enforced **before** install: exact byte size **and** SHA-256 must match the curated
  descriptor, or the download is discarded (`checksumMismatch`/`contentLengthMismatch`).
- `reconcileLocalModels()` (call at launch) repairs interrupted lifecycles: recovers a verified orphan file
  (interrupted finalize), drops broken records/dirs, clears stale resume tokens, preserves legitimate
  paused downloads. Idempotent. Verified across all these cases.
- Persistence has an explicit **schema version** (#10): legacy records decode as v1, older versions migrate
  forward, a newer-than-supported record is refused (typed) rather than misread.

## Storage behavior

Everything lives in the app sandbox (`…/Library/Application Support/esh/models/…`). `installPlan(for:)`
does a storage preflight (free space vs model + 512 MB reserve) and Model-Fit over the live `DeviceProfile`
before downloading; insufficient storage fails early. `remove` deletes the model, record, and resume data.

## Memory-pressure behavior (#7)

- `DeviceProfile` reports honest iOS process-available memory (`os_proc_available_memory`), thermal, and
  low-power state (M5). `installPlan` refuses `unsupported` fit and warns on `tight`/`unlikely`.
- Embedded GGUF weights are mmap/file-backed and paged lazily; `unload()` releases compute/Metal buffers
  (~98 MB recovered, measured). The runtime stays usable after unload/reload.
- Policy: prefer app stability over model availability. esh does not try to defeat iOS jetsam; if a model
  cannot be loaded it fails with `modelLoadFailed` rather than risking a low-memory termination.

## Background / foreground lifecycle (#8)

iOS does not guarantee background execution, and esh does not promise it. Documented behavior:
- **Download** uses `URLSessionDownloadTask`; if the app is backgrounded/suspended mid-download the task may
  be paused/interrupted — resume data is persisted and `install` resumes on next foreground call. An
  interrupted download never produces an install record.
- **Inference** in progress when the app is suspended may be cancelled by the OS; callers get
  `CancellationError` or a typed failure, and the runtime is reusable on return to foreground.
- **Kill + relaunch**: installs survive (verified). Call `reconcileLocalModels()` at launch to clear any
  state left by a kill mid-lifecycle.
Hosts that need long downloads to continue in background should adopt a background `URLSession` at the app
layer; that is not part of the SDK’s promise today (see Known limitations).

## Privacy & security (#11)

- **No telemetry.** The SDK path (`EshCore`/`EshRuntime`/`EshLlamaCpp`) makes no analytics/telemetry calls;
  the only network use is downloading a model the host explicitly requested.
- **HTTPS only.** Downloads must be HTTPS (loopback permitted for tests); http-to-remote and `file://` are
  refused (`insecureSource`).
- **Checksum before install.** SHA-256 + size are verified before a file becomes an install.
- **No path traversal.** Model ids are validated (`[A-Za-z0-9._-]`, no `/`/`..`) before building any
  sandbox path (`invalidModelID`); untrusted descriptor metadata cannot escape the sandbox.
- **No hidden cloud fallback.** esh ships no remote backend; `localOnly` is always honored.
- **No OpenAI/ChatGPT credentials** exist in the SDK path (that integration is macOS-CLI-only).
- **No prompt logging.** The SDK path does not log prompt/generation text.

## Dependency & license inventory (#12)

**`EshRuntime` only** — no third-party Swift packages. Apple frameworks: Foundation, FoundationModels,
CryptoKit, Network, plus (in EshCore) AVFoundation/CoreGraphics/CoreMedia/ImageIO/UniformTypeIdentifiers/
Vision as needed. **`EshRuntime` + `EshLlamaCpp`** — adds **llama.cpp** (pinned commit
`4a89937354190cef5a97baf8eeb17336105eb72d`, **MIT**) as a prebuilt binary (`CLlama`/`llama.xcframework`).
Curated models are **Apache-2.0** (Qwen2.5 0.5B / 1.5B Instruct GGUF). **Action item for GA:** the repo has
no top-level `LICENSE` file yet — add the esh license + a llama.cpp MIT notice before public distribution.

## Device matrix (#13)

| Device class | Status |
|---|---|
| iPhone 17 (iPhone18,3, ~8 GB) | **Validated** — Apple FM + embedded GGUF + managed install proven on device (M4/M7/M8). Primary target. |
| Lower-memory iPhone (e.g. iPhone 12 Pro, 6 GB) | **BLOCKED / not tested** — device is paired but currently unavailable. Recommended minimum for the 0.5B GGUF; 1.5B is `tight` below 8 GB. |
| iPad / higher-memory Apple device | **Not tested** — no device available. Expected to work (same code path, more headroom). |

**Minimum supported hardware policy (current):** Apple FM requires an Apple-Intelligence-capable device on
iOS 26+. Embedded GGUF: 0.5B (Q4_K_M, ~380 MB) is comfortable on 4 GB+; 1.5B (~940 MB) recommended on 8 GB+.

## Performance baselines (#14) — measured on iPhone 17 (iOS 26.x)

Documented thresholds for manual/device regression tracking (not CI-gated — these are device-only and
noisy). From M7/M8 on-device runs:

| Metric | Apple FM | Embedded GGUF (Qwen2.5-1.5B Q4_K_M) |
|---|---|---|
| First call | ~1.42 s (TTFT 1418 ms) | ~19 s first-ever load+gen (cold mmap+Metal) |
| Warm call | ~0.18 s (TTFT 182 ms) | ~0.2–0.3 s (short gens); reload ~0.21 s |
| Throughput | not exposed | ~35–50 tok/s (sub-100 ms warm TTFT) |
| Process-available memory | — | 3358 MB before → ~3090 MB during gen; ~98 MB freed on unload |
| Storage | 0 (system model) | 940 MB (1.5B) / ~380 MB (0.5B) |

A meaningful regression = warm TTFT or tok/s materially worse than the above, or first-load far beyond
~19 s, on the same device/OS. Re-measure via `Examples/EshIOSProbe` or `Examples/EshCleanRoom`.

## Regression status

- macOS unit suite: **674 / 674 pass** (`swift test`) — includes M10 schema, typed-error, durability,
  concurrency, security, and lifecycle-stress suites.
- Fresh-checkout build (no Vendor/symlink/SSD): macOS `swift build` complete; iOS `EshRuntime`+`EshCore`
  BUILD SUCCEEDED.
- iOS Simulator: EshCore, EshRuntime, EshIOSProbe, EshCleanRoom all build.
- **Clean-room functional run (iOS 26.5 Simulator, via the public API):** `EshRuntime().generate(prompt:)`
  → **Apple FM** (`backend=apple`, "pong"); `EshRuntime.withEmbeddedGGUF()` → `reconcileLocalModels()`
  consistent → `installPlan` fit=comfortable → `install(.qwen05B)` downloaded+verified+persisted (384 MB
  on disk) → `.pinned` generate selected `backend=gguf` and returned tokens. GGUF *text quality* is a
  device property (coherent on iPhone 17 in M7/M8; the Simulator's Metal compute yields garbled tokens —
  the SDK path itself is fully exercised).
- **Physical iPhone 17:** app installs; the live launch this session was blocked by the device being locked
  (screen lock is a per-device user action). Apple FM + embedded GGUF + managed install were previously
  proven live on this exact device (M4/M7/M8) and M10 did not change those execution paths.

## Known limitations

- **Background downloads/inference** are not guaranteed by the SDK (iOS constraint); adopt a background
  `URLSession` at the app layer if needed.
- **Streaming** is real for GGUF; Apple FM emits a single token event today (non-incremental).
- **Curated catalog** is intentionally tiny (two Qwen2.5 sizes). Adding models is a data change.
- **Device matrix** below 8 GB and iPad are not yet hardware-validated.
- **llama.cpp binary hosting** (release `binaryTarget(url:checksum:)`) is code-complete and the checksum is
  pinned, but publishing the release asset is a maintainer step (see SDK_PACKAGING.md).
- **No `LICENSE` file** in the repo yet (see inventory).
