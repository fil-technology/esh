# esh — M2 Apple Foundation Models: physical-device validation

**Milestone:** M2 — Apple Foundation Models on iOS (ClickUp `86eywc26e`).
**Status of live on-device inference:** ✅ **RESOLVED in M4** via an app host — see
[`IOS_APPLE_FM_DEVICE_VALIDATION.md`](IOS_APPLE_FM_DEVICE_VALIDATION.md) for the measured iPhone 17 results
(Apple FM available; first call 2.017 s, warm 0.226 s, output "pong", through `EshRuntime → AppleBackend →
FoundationModels`). The note below records why the *test-based* harness could not run on device (SwiftPM
tool-hosted testing), which is why M4 used an `EshRuntime`-backed app instead.

## What the on-device harness is

M2 uses esh's own test suite as the smallest physical-device harness — no separate app UI. Two tests in
`Tests/EshCoreTests/AppleBackendTests.swift` drive the **exact required path**:

```
InferenceBackendRegistry → AppleBackend → AppleBackendRuntime → AppleIntelligenceService → FoundationModels / SystemLanguageModel
```

- `appleDeviceInferenceMeasured` — runs a generation through the esh registry/backend and prints `ESH-M2 …`
  lines: availability, OS version, first-/second-call latency, chunk count (streamed vs single-chunk),
  backend/model metadata, and `RESULT=PASS`/`SKIP`. Honest typed status when Apple FM is unavailable.
- `realAppleGenerationProducesText` — asserts non-empty output through esh.

Both are gated by `ESH_RUN_APPLE_TESTS=1` so ordinary CI/hosts stay hermetic.

A dedicated shared scheme `EshCoreDeviceTests` (in `.swiftpm/xcode/xcshareddata/xcschemes/`) tests **only
`EshCoreTests`** — it excludes `EshUITests`, whose dependency on the macOS-only `esh` executable cannot build
for iOS.

## Exact reproduction command (run when the device is unlocked & connected)

```bash
xcodebuild test \
  -scheme EshCoreDeviceTests \
  -destination 'platform=iOS,id=<DEVICE_UDID>' \
  -only-testing:EshCoreTests/AppleBackendTests \
  -allowProvisioningUpdates -skipPackagePluginValidation \
  DEVELOPMENT_TEAM=46JTU2GRTD \
  TEST_RUNNER_ESH_RUN_APPLE_TESTS=1
```

Then read the measured results:

```bash
# from the xcodebuild output, or:
xcrun devicectl device console --device <DEVICE_UDID> | grep ESH-M2
```

## Why it is BLOCKED here — CONFIRMED ROOT CAUSE

Target device present and capable: **iPhone 17 (iPhone18,3), iOS 26.6.2 (23G90), Developer Mode: Enabled,
booted, and `connected` (online).** With the device unlocked and connected, the pipeline succeeds through
package resolution, device `arm64` build of `EshCore`, and code signing — and then hits a **structural
SwiftPM limitation**, not a device/environment flake:

```
error: Cannot test target "EshCoreTests" on "Sviatophone": Tool-hosted testing is unavailable on
device destinations. Select a host application for the test target, or use a simulator destination instead.
(xcodebuild exit 70)
```

A SwiftPM **unit-test target runs "tool-hosted"** (a CLI test runner). That works on macOS and the iOS
**Simulator**, but a **physical device requires the test bundle to be hosted inside an application**. So the
test-based harness — running `AppleBackendTests` via `xcodebuild test` — **cannot execute on a physical
device at all**, regardless of connectivity. (Earlier `exit 70` "timed out … destinations to become
available" runs were the separate issue of the WiFi device not yet being `connected`; that is now resolved —
the device shows `connected`/online. Transport is localNetwork/WiFi; no USB.)

This is not a defect in the esh Apple backend, and per the milestone constraint esh code was **not** changed
to work around it.

## Path to close it: a minimal app host

On-device inference requires an **app host** (the other harness form the M2 brief allows: "a minimal iOS
sample app, or a dedicated Xcode integration target"). The smallest option is an `Examples/EshIOSProbe`
SwiftUI app that links `EshCore` and, on launch/button, runs the SAME esh path the test drives
(`InferenceBackendRegistry → AppleBackend → AppleBackendRuntime → AppleIntelligenceService →
FoundationModels`) and prints the `ESH-M2 …` lines to the device console. Because SwiftPM cannot emit an iOS
`.app`, this needs a small `.xcodeproj` (one app target + the local package). That is a new (non-production)
harness artifact, held for approval rather than scaffolded unilaterally.

Everything else in M2 is complete and green (below); only the live on-device generation numbers remain, and
they are unobtainable through the SwiftPM test harness on a device.

## What IS validated (deterministic, no device)

- macOS `swift test`: **621/621 pass** (619 baseline + the 2 Apple M2 tests).
- iOS Simulator build of `EshCore`: green (clean).
- Apple-only iOS registry assembly resolves Apple and never substitutes Apple for a pinned non-Apple format
  (`iOSAppleOnlyAssemblyResolvesAppleAndNeverSubstitutesForPinnedNonApple`).
- Typed availability status + JSON round-trip; `generate()` throws (never silently degrades) when unavailable.

> Note: the iOS Simulator cannot substitute for this test — Apple Foundation Models on-device inference is not
> available in the Simulator, so live generation must be proven on physical hardware.
