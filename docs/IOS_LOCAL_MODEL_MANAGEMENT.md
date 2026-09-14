# esh — iOS Local Model Management (M8)

App-managed install / inspect / use / remove of GGUF models on iOS — no manual file copying. Model
management, **not** a marketplace. Built on the existing esh abstractions; the GGUF *executor*
(`LlamaCppEmbeddedBackend`, M7) stays app-injected, so nothing here imports llama.cpp.

```
EshRuntime → LocalModelManager → curated descriptor → preflight → download → verify → install record
           → Model Fit → explicit GGUF pin → LlamaCppEmbeddedBackend (app-injected) → llama.cpp → GGUF
```

## Reused vs new

**Reused (EshCore):** `ModelSpec`, `ModelInstall`, `ModelManifest`, `ModelStore`/`FileModelStore`,
`StorageService`, `ResumeSupport`, `ModelFitService` + `HostMachineProfile`, `DeviceProfile` (M5),
`InferenceBackendRegistry`/`EshRuntime` (M3), `LlamaCppEmbeddedBackend` (M7).
**New (EshRuntime target, portable):** `LocalModelDescriptor` + `LocalModelCatalog`, `LocalModelState`,
`LocalModelInstallPlan`, `LocalModelError`, `LocalModelManager` (actor), `ModelDownloadCoordinator` (the
background-capable download layer — see below; it replaced the earlier foreground `ResumableDownloader`). No
new iOS model database — installs are ordinary esh `ModelInstall` records.

## Storage layout (sandbox)

Root = `PersistenceRoot.default()` → on iOS the app container `…/Library/Application Support/esh` (M1).

```
<root>/models/manifests/<id>.json        # install record (ModelManifest → ModelInstall), via FileModelStore
<root>/models/installs/<id>/model.gguf   # the verified model file
<root>/models/installs/<id>/model.resume # URLSession resume data while a download is paused/interrupted
```

Deterministic, app-controlled, no macOS external-volume assumptions. A model is **installed** only when both
the manifest record exists **and** `model.gguf` is present; a lone record or a lone resume file never counts
as installed.

## Descriptor schema (`LocalModelDescriptor`)

`id`, `displayName`, `sourceURL` (direct GGUF), `repository`, `license`, `expectedBytes`, `sha256`,
`quantization`, `parameterCountB`, `capability`, `recommendedContext`, `recommendedHardwareClass`. The catalog
(`LocalModelCatalog.models`) is data-driven — adding a model is a new array entry, no manager changes.
Current curated set (both **Apache-2.0**, exact upstream LFS size + SHA-256; 1.5B cross-checked against M7):

| id | size | sha256 (short) | fit class (8 GB iPhone) |
|---|---|---|---|
| `qwen2.5-0.5b-instruct-q4km` | 397,808,192 | `6eb923e7…8653` | comfortable |
| `qwen2.5-1.5b-instruct-q4km` | 986,048,768 | `1adf0b11…c3370` | comfortable |

## Download lifecycle

`LocalModelState`: `notInstalled → downloading(progress) → (paused) → verifying → installed / failed(reason)`.
Download uses `URLSessionDownloadTask` (native, efficient — not byte-by-byte) via `ModelDownloadCoordinator`,
the single background-capable download layer (on iOS a `URLSessionConfiguration.background(withIdentifier:)`
session; ephemeral off-device — see "Background downloads" below). Progress comes from `didWriteData`;
**cancellation** cancels the task and persists resume data (`model.resume`) so a later `install` resumes; a
cancelled or failed download **never** produces an install record. Finalize is atomic: the transfer is staged
(`model.download`), verified (size + SHA-256), then moved into the install dir — so `verifying` maps to a
completed-but-not-yet-verified transfer, and a model is never `installed` before verification succeeds.

## Verification

Before a download can become a `ModelInstall`: (1) **byte size** must equal `descriptor.expectedBytes`;
(2) **SHA-256** of the downloaded file must equal `descriptor.sha256`. A checksum mismatch deletes the file
(corrupt) and throws `checksumMismatch`; a size mismatch throws `contentLengthMismatch`. Only then is the file
moved into place and the manifest saved.

## Model Fit preflight

`installPlan(for:)` = storage preflight + Model Fit over the **DeviceProfile** (M5):
`DeviceProfile → HostMachineProfile(deviceProfile:) → ModelFitService.assess` → `comfortable/fits/tight/
unlikely/unsupported/unknown`. Storage: `availableStorageBytes` vs `expectedBytes + 512 MB` reserve.
`suitable = storageSufficient && fit != .unsupported`. `tight`/`unlikely` are **allowed** (explicit advanced
use) but surfaced as warnings; insufficient storage fails the install **early** with a typed reason.
`"file fits on disk"` is never treated as `"safe to run"` — memory fit is separate.

## Persistence & deletion

Install records live in the sandbox model store and **survive app restarts** (verified on device).
`remove(_:)` deletes the manifest **and** the install directory (model + resume files); afterwards the model
no longer resolves (`isInstalled == false`, state `.notInstalled`).

## Public `EshRuntime` API

```swift
let models = await runtime.localModels()                 // [LocalModelStatus] (descriptor + state)
let plan   = await runtime.installPlan(for: descriptor)  // storage + Model Fit preflight
try await runtime.install(descriptor) { progress in … }  // download → verify → record (cancellable/resumable)
try await runtime.remove(descriptor)                     // delete files + record
let r = try await runtime.generate(.init(prompt: "…", constraints: .pinned(descriptor.id)))
```

The app never handles filesystem paths. Generation of an installed GGUF requires the app to have injected the
`.gguf` backend (`LlamaCppEmbeddedBackend`) into the registry (it carries the llama.cpp dependency, kept out of
the portable core).

## Auto policy (unchanged)

```
Auto            → Apple Foundation Models (first)
explicit pin    → installed GGUF → LlamaCppEmbeddedBackend
```

A downloaded model appearing in the system does **not** make Auto select it. A pinned GGUF that fails to load
fails with a typed error — **never** a silent fallback to Apple.

## Physical-device evidence (iPhone 17, iOS 26.6.2)

App-managed lifecycle for `qwen2.5-0.5b-instruct-q4km` (397 MB), downloaded by the app from Hugging Face
(not the manually-copied M7 file). `ESH-M8` log:

```
plan downloadMB=379 storageFreeMB=57656 fit=comfortable suitable=true
download progress=0% → 25% → 50% → 75% → 100%
installed downloadTime=16.1 s          # verified (size + SHA-256), recorded
generateAfterInstall backend=gguf model=qwen2.5-0.5b-instruct-q4km text="Game"   # runs via managed install
# on relaunch:
wasInstalledAtLaunch=true → persistence=confirmed install-survived-restart
generateAfterRestart backend=gguf … text="Game"
removed … stillInstalled=false         # deletion; model no longer resolves
```

Failure cases covered by deterministic tests (`LocalModelManagerTests`, localhost server + temp store):
insufficient storage (plan + fast-fail), checksum mismatch, content-length mismatch, duplicate install,
install record without file (not installed), remove-non-installed, and (via `EshRuntimeTests`) explicit
generation against a non-installed / unwired-backend pin failing typed with **no Apple substitution**.

## Background downloads (RC follow-up)

Downloads are **OS-managed and background-capable** on iOS. `LocalModelManager` drives one
`ModelDownloadCoordinator` whose `URLSession` is `URLSessionConfiguration.background(withIdentifier:
"technology.fil.esh.model-downloads")` on iOS (`sessionSendsLaunchEvents`, non-discretionary,
`waitsForConnectivity`) and ephemeral/foreground off-device (CLI/tests). This replaces the old foreground
`ResumableDownloader` — one download layer, not two.

- **Cross-relaunch:** each task is tagged with its model id (`taskDescription`), and a `PendingDownload`
  record (`download.json`: phase + staged path + expected size/SHA) is persisted next to the install dir. A
  fresh runtime recreates the session (same identifier), iOS re-delivers outstanding events, and
  `reconcile()` finalizes any transfer that completed while suspended. The host need not retain the runtime.
- **Completion while suspended:** the transfer stages `model.download` and the record moves to `downloaded`
  (state `.verifying` / pending verification). Verification (size + SHA-256) + atomic install run in the
  background window if granted, otherwise on the next `reconcileLocalModels()`. A model is never `installed`
  before verification succeeds; a corrupt completed transfer is discarded and never installs.
- **Cancellation:** cancelling the `install` Task cancels the transfer and persists resume data, so a later
  `install` continues rather than restarts. Duplicate concurrent installs remain serialized per model id.
- **Host hook (the only one):** forward `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
  to `EshRuntime.handleBackgroundSessionEvents(identifier:completionHandler:)`. See docs/PRODUCTION_READINESS.md
  for the full scenario table (background / lock / suspend / terminate / force-quit / network drop).

## Not in M8 (per scope)

No Hugging Face browser/search, no marketplace, no large catalog, no Auto changes, no background
App-Store-style downloader, no cloud sync, no on-device conversion/quantization, no multiple simultaneously
resident GGUF models, no `EshMacRuntime` extraction (tracked as the next cleanup/packaging milestone).
