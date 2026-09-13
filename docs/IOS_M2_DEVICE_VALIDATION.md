# esh — M2 Apple Foundation Models: physical-device validation

**Milestone:** M2 — Apple Foundation Models on iOS (ClickUp `86eywc26e`).
**Status of live on-device inference:** ⛔ **BLOCKED on device availability** (not on code). Everything else is done and green.

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

## Why it is BLOCKED here

Target device present and capable: **iPhone 17 (iPhone18,3), iOS 26.6.2 (23G90), Developer Mode: Enabled,
paired over localNetwork, booted.** The pipeline succeeds through package resolution, device `arm64` build of
`EshCore`, and code signing (`-allowProvisioningUpdates`, team `46JTU2GRTD`). It then fails only at the final
install/run step:

```
error: Timed out waiting for all destinations matching the provided destination specifier to become available
(xcodebuild exit 70)
# earlier: "The developer disk image could not be mounted on this device."
```

i.e. the device is reachable only over a network tunnel and is not in a deployable state (locked / not
front-most / dev disk image unmountable). Unlocking the device and connecting it via USB (or keeping it
unlocked and trusted on the same network) resolves this. This is an environment/availability limitation, not
a defect in the esh Apple backend.

## What IS validated (deterministic, no device)

- macOS `swift test`: **621/621 pass** (619 baseline + the 2 Apple M2 tests).
- iOS Simulator build of `EshCore`: green (clean).
- Apple-only iOS registry assembly resolves Apple and never substitutes Apple for a pinned non-Apple format
  (`iOSAppleOnlyAssemblyResolvesAppleAndNeverSubstitutesForPinnedNonApple`).
- Typed availability status + JSON round-trip; `generate()` throws (never silently degrades) when unavailable.

> Note: the iOS Simulator cannot substitute for this test — Apple Foundation Models on-device inference is not
> available in the Simulator, so live generation must be proven on physical hardware.
