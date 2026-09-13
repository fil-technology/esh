# esh — Apple Foundation Models physical-device validation (M4)

✅ **SUCCESS.** Real on-device Apple Foundation Models inference through esh's **public `EshRuntime` SDK**,
captured on a physical iPhone. This closes the M2 device-validation follow-up.

## Path validated (no direct Foundation Models call)

```
EshIOSProbe (app)
 → EshRuntime.generate(...)            // public SDK facade
 → InferenceBackendRegistry            // platform assembly: iOS = Apple only
 → AppleBackend
 → AppleBackendRuntime
 → AppleIntelligenceService
 → FoundationModels / SystemLanguageModel
 → result
```

The probe imports only `EshRuntime` (+ `EshCore` value types) and never constructs `AppleBackend`,
`AppleIntelligenceService`, or `LanguageModelSession` directly.

## Environment

| | |
|---|---|
| Device | iPhone 17 (`iPhone18,3`) |
| iOS | 26.6.2 (build 23G90) |
| Apple Intelligence | **available**, on-device (no download); `hasReadyBackend = true` |
| Signing | Apple Development (team `L7T5538V86`, wildcard dev profile), `-allowProvisioningUpdates` |
| Deploy | `devicectl` install + `process launch --console` over the network tunnel |

## Measured results (verbatim `ESH-M4` console output — not fabricated)

```
ESH-M4 os=26.6.2 device=iPhone18,3
ESH-M4 availability=available available=true onDevice=true hasReadyBackend=true detail=Apple Intelligence on-device model is available (no download required).
ESH-M4 firstCall  elapsed=2.017240959 s  backend=apple  model=apple-intelligence  reason="no-download on-device provider available"  localOnly=true  ttftMs=2013.8  text="pong"
ESH-M4 secondCall elapsed=0.225653750 s  backend=apple  model=apple-intelligence  reason="no-download on-device provider available"  localOnly=true  ttftMs=223.3   text="pong"
ESH-M4 RESULT=PASS
```

Prompt: `"Reply with exactly one word: pong"` → generated output: **`pong`** (both calls).

| Metric | Value |
|---|---|
| Apple Intelligence status | `available` (typed `AppleIntelligenceAvailability.available`) |
| First-call latency (cold) | **2.017 s** (includes first `LanguageModelSession` spin-up) |
| Second-call latency (warm) | **0.226 s** |
| TTFT | ≈ full response time (see streaming note) — 2013.8 ms cold / 223.3 ms warm |
| Streaming | **single chunk** — Apple FM returns the whole response; esh emits it as one `.token` then `.completed` |
| Selected backend | `apple` |
| Selected model | `apple-intelligence` |
| Selection reason | `no-download on-device provider available` (Auto) |
| `localOnly` satisfied | `true` |
| Generated text | `pong` |

## Cancellation

Cancellation is validated deterministically in `Tests/EshRuntimeTests` (`cancellationPropagates`): the facade
re-checks cancellation after the stream loop, so a cancelled generation throws `CancellationError` instead of
returning partial text. The probe app also exposes a Cancel control. Because Apple FM returns a single
non-streamed chunk, on-device cancellation is effective between calls rather than mid-token.

## Reproduce

```bash
cd Examples/EshIOSProbe && xcodegen generate
xcodebuild -project EshIOSProbe.xcodeproj -scheme EshIOSProbe \
  -destination 'platform=iOS,id=<DEVICE_UDID>' -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=<YOUR_TEAM> build
xcrun devicectl device install app --device <DEVICE_UDID> \
  "<derivedData>/Build/Products/Debug-iphoneos/EshIOSProbe.app"
xcrun devicectl device process launch --console --terminate-existing \
  --device <DEVICE_UDID> technology.fil.EshIOSProbe | grep ESH-M4
```

The app auto-runs the probe on launch (`ContentView.task → ProbeModel.autoProbe()`); it also has an
interactive prompt field + Generate/Cancel.

---

## M5 — DeviceProfile captured on the same iPhone 17

Read through the public `await runtime.deviceProfile()` API (verbatim `ESH-M5` console output):

```
ESH-M5 platform=iOS model=iPhone18,3 os=Version 26.6.2 (Build 23G90)
       physicalBytes=8044216320  availableBytes=3525049520 availableKind=processAvailable
       storageBytes=61177738126  thermal=nominal  lowPower=false  appleFM=true
```

| Field | Value | Notes |
|---|---|---|
| platform | `iOS` | |
| deviceModel | `iPhone18,3` | `sysctl hw.machine` |
| osVersion | Version 26.6.2 (Build 23G90) | |
| physicalMemory | 8,044,216,320 B (**7.49 GiB**) | `ProcessInfo.physicalMemory` (always known) |
| availableMemory | 3,525,049,520 B (**3.28 GiB**) | **`processAvailable`** — `os_proc_available_memory()`, i.e. headroom for THIS process before jetsam (NOT total free RAM) |
| availableStorage | 61,177,738,126 B (**56.98 GiB**) | `volumeAvailableCapacityForImportantUsage` in the app sandbox |
| thermalState | `nominal` | `ProcessInfo.thermalState` |
| lowPowerMode | `false` | `ProcessInfo.isLowPowerModeEnabled` |
| supportsAppleFoundationModels | `true` | from `AppleIntelligenceService` (not duplicated) |

Every value is measured; nothing is inferred from the model name. On a platform where a value is not
honestly available, esh reports `nil`/`unknown` (e.g. `availableMemoryKind` would be `.unknown`). Generation
through `EshRuntime` continued to work in the same session (no regression).
