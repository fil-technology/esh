# esh v2.4.0-rc.4 — llama.cpp Coexistence (Report)

Status: **coexistence proven; rc.4 published.** `rc.1`, `rc.2`, `rc.3` left immutable. One gate
(on-device *execution*) is blocked by code-signing provisioning and is marked honestly below.

## 1. Root cause of the collision

`EshLlamaCpp` and `LLM.swift` both embed llama.cpp built by the **same upstream `build-xcframework.sh`**,
producing an artifact with identical identity on every axis:

| Axis | esh (rc.3) | LLM.swift 2.1.0 |
|---|---|---|
| Framework bundle | `llama.framework` | `llama.framework` |
| Clang module | `llama` | `llama` |
| Mach-O install name | `@rpath/llama.framework/Versions/Current/llama` | same |
| Bundle id | `org.ggml.llama` | `org.ggml.llama` |
| Bundled dSYM | `llama.dSYM` | `llama.dSYM` |

Linking both into one app → **"Multiple commands produce '…/llama.framework'"** (and separately
`llama.dSYM`). Reproduced against the published rc.3 + LLM.swift 2.1.0:
- **iOS app (xcodebuild):** `Multiple commands produce '…/Debug-iphonesimulator/llama.dSYM/…'`.
- **SwiftPM (`swift build`):** the two `llama.framework` bundles collapse to one `.build/…/llama.framework`
  (`[40/49] Copying llama.framework`, a single copy), and LLM.swift then compiles against **esh's**
  `llama.h` — a *different* llama.cpp version (`llama_sampler_init_penalties` signature mismatch). This also
  proves the two copies are not interchangeable, so deduping to one is not an option.

Crucially this is a **bundle/module identity collision, not a native-symbol collision** (see §4).

## 2. Chosen isolation strategy

**Rename esh's artifact to an esh-private namespace — no native-symbol prefixing.** esh's llama.cpp is a
*self-contained dynamic framework* (one dylib bundling llama + ggml + gguf, Metal embedded, `otool -L` shows
only system frameworks). Renaming every identity axis makes it distinct from any other llama.cpp consumer;
the dynamic two-level namespace (see §4) makes symbol prefixing unnecessary. The bundled dSYMs are dropped
(second collision + ~72% of the artifact). Implemented as a **deterministic post-build transform** on the
same pinned bits: `scripts/namespace-llama-xcframework.sh` (`install_name_tool` + modulemap rewrite +
`PlistBuddy` bundle ids + drop dSYMs + ad-hoc `codesign`); `scripts/build-llama-xcframework.sh` runs it so a
from-source rebuild emits `Vendor/esh_llama.xcframework` directly. No upstream source patched; only Apple
tools used (no new dependency/license).

## 3. Final framework / module names

| | esh (rc.4) |
|---|---|
| XCFramework | `esh_llama.xcframework` |
| Framework bundle | `esh_llama.framework` |
| Clang module (Swift `import`) | `esh_llama` |
| Mach-O install name | `@rpath/esh_llama.framework/[Versions/Current/]esh_llama` |
| Bundle identifier | `technology.fil.esh.esh-llama` (hyphen — `_` is invalid in CFBundleIdentifier) |
| SwiftPM binaryTarget | `EshCLlama` |

## 4. Native-symbol isolation strategy

**Symbols are shared by NAME but isolated by Apple's two-level namespace — not prefixed, hidden, or
shimmed.** esh's `esh_llama` dylib and LLM.swift's `llama` dylib each export the full `llama_*` (240),
`ggml_*` (1124), `gguf_*` (61) symbol set. Because both are **dynamic** frameworks, the app links against
each *by (framework, symbol)*: `EshLlamaCpp`'s calls bind to `esh_llama.framework`'s symbols and `LLM`'s
bind to `llama.framework`'s. So:
- **No duplicate-symbol link errors** (symbols are not statically merged into the app binary).
- **Isolated runtime state** — each dylib has its own ggml backend registry and Metal device; one engine's
  `llama_backend_init()` / global state does not touch the other's.

A static library would require symbol prefixing (`esh_llama_*`); this dynamic framework does not, which is
why a rename is sufficient and the public `llama_*` C call sites in `EshLlamaCpp` are unchanged.

## 5. Package / API changes

- `Package.swift`: binaryTarget `CLlama` → `EshCLlama`; path/url → `esh_llama.xcframework` (rc.4 asset);
  checksum updated; `hasEmbeddedLlama` checks `Vendor/esh_llama.xcframework`.
- `Sources/EshLlamaCpp/LlamaCppEmbeddedBackend.swift`: `import llama` → `import esh_llama` (internal only).
- **Public API unchanged:** `import EshRuntime` / `import EshLlamaCpp` / `EshRuntime.withEmbeddedGGUF()`.
- New `scripts/namespace-llama-xcframework.sh`; `build-llama-xcframework.sh` + CI updated; NOTICE/CHANGELOG/
  SDK_PACKAGING updated.

## 6. Standalone esh result

- Root `swift build` (EshCore + EshRuntime + EshLlamaCpp via `esh_llama`): **Build complete**.
- iOS Simulator `xcodebuild -scheme EshRuntime` and `-scheme EshLlamaCpp`: **BUILD SUCCEEDED**.
- `EshRuntime`-only consumer still links **no** llama.cpp (portable graph unchanged from rc.3).
- Runtime generation via `EshLlamaCpp` works (see §8).

## 7. LLM.swift coexistence build result

`LLM` + `EshRuntime` + `EshLlamaCpp` in one target:
- **macOS executable (`swift build`):** `[40/50] Copying llama.framework` + `[41/50] Copying
  esh_llama.framework` → **Build complete**; the binary links **both** `@rpath/llama.framework/…` and
  `@rpath/esh_llama.framework/…` and launches (dyld loads both dylibs).
- **iOS Simulator app (xcodebuild):** **BUILD SUCCEEDED**; the `.app/Frameworks` embeds **both**
  `esh_llama.framework` (`technology.fil.esh.esh-llama`) and `llama.framework` (`org.ggml.llama`).
- **iOS device app (`generic/platform=iOS`, arm64):** **BUILD SUCCEEDED** (unsigned).
- **Published remote rc.4** (`esh exact 2.4.0-rc.4` + LLM.swift): resolves, downloads the remote
  `esh_llama.xcframework` binaryTarget, both frameworks copy → **Build complete** (see §13).
- No "Multiple commands produce", no duplicate symbol, no module redefinition in any of the above.

## 8. Same-process runtime result

macOS process linking both frameworks, model = Qwen2.5-0.5B-Instruct Q4_K_M GGUF, prompt "What is 2+2?":

```
A1 LLM.swift : 4        (order A: LLM.swift then esh)
A2 EshLlama  : 4
B1 EshLlama  : 4        (order B: esh then LLM.swift, reversed)
B2 LLM.swift : 4.0
stress[1..3] : both engines alternated 3× — coherent output each time
== coexistence runtime proof complete (no crash, both engines produced output) ==
```

Both engines load a GGUF, generate coherent output, and unload, in **both orders** plus a bounded stress
loop, in one process — no crash, no cross-engine state corruption, Metal initialised by both.

## 9. iOS result

- iOS **Simulator** coexistence build: **PASS** (both frameworks embed, distinct bundle ids).
- iOS **device** build (arm64 slices link): **PASS** (unsigned, `generic/platform=iOS`).
- On-**device execution**: **NOT PERFORMED.** The iPhone 17 is paired/available, but development install
  requires a provisioning profile for the app id, and `-allowProvisioningUpdates` fails with *"No Account
  for Team … Add a new account in Accounts settings"* — no Apple developer account is logged into Xcode, and
  the only on-disk profiles are expired and for a different team (L7T5538V86). Minting a profile / registering
  the app id is an Apple-account action that requires the user; it is not a coexistence problem. The device
  Metal path is exercised functionally by the macOS run (§8) and the device build proves linkage.

## 10. macOS result

Build **PASS** and runtime dual-inference **PASS** (§8). macOS CLI/runtime package (`macos/`) unaffected by
rc.4 and still builds.

## 11. Binary-size impact (iOS device, arm64 embedded dylib)

| Configuration | Embedded llama.cpp dylib |
|---|---|
| legacy only (LLM.swift `llama`) | 3.7 MB |
| esh only (`esh_llama`) | 7.7 MB |
| legacy + esh (both) | **11.4 MB** |

Two independent llama.cpp copies is inherent to safe isolation (they are different versions/builds). dSYMs
are not embedded in the `.app`, so dropping esh's dSYMs does not change app size (it shrank the *download*
artifact from ~96 MB to ~14 MB). esh's slice is larger than LLM's because esh's upstream build includes more
of ggml; not tuned in rc.4 (no perf/size rewrite in scope).

## 12. Regression results

- Portable suite (`swift test`): **468 tests / 74 suites passed**.
- iOS SDK build gate (`EshRuntime` + `EshLlamaCpp`, iOS Simulator): **BUILD SUCCEEDED**.
- macOS package (`swift build --package-path macos`, CLI + runtime): **Build complete**.
- macOS suite: unchanged by rc.4 (rc.4 touches only the root llama artifact + `EshLlamaCpp` import); rc.3
  ran **211 tests / 40 suites** green on identical `macos/` code.
- `EshRuntime`-only consumers remain lightweight and link no llama.cpp — rc.3 packaging split not regressed.

## 13. Published rc.4 release / tag / artifact / checksum

- Tag **`v2.4.0-rc.4`** → commit `e83b2c9`, pushed.
- Release: <https://github.com/fil-technology/esh/releases/tag/v2.4.0-rc.4> (prerelease).
- Asset: `esh-llama-xcframework-4a8993735419.zip` (14,318,719 bytes).
- SwiftPM checksum: `4366e678d655672b6f9e990c1b2a6a23df6982cd063beabced97126d4454717e` — **verified by
  re-downloading the published asset** and matching `Package.swift`.
- Same pinned llama.cpp commit `4a89937354190cef5a97baf8eeb17336105eb72d`. rc.1/rc.2/rc.3 untouched.

## 14. Can LLMHub safely re-add `EshLlamaCpp`?

**Yes.** `esh exact "2.4.0-rc.4"` + `LLM.swift` build together in one app (macOS + iOS Simulator + iOS
device build, from the published remote tag) with no framework/module/duplicate-symbol collision and no
consumer-side workaround — no manual renames, no embed-phase edits, no linker flags, no excluded archs, no
patched checkout, no local paths, `LLM.swift` untouched. Both engines run in one process.

## 15. Remaining limitations

- **On-device execution not run** (provisioning/Apple-account gated; §9). Everything up to and including the
  signed step is blocked only by signing, not coexistence; device *build* passes and macOS *runtime* passes.
- **No bundled llama.cpp dSYM** in `esh_llama.xcframework` (dropped to fix the `llama.dSYM` collision and
  shrink the artifact). App-level symbolication of your own code is unaffected; consumers needing llama.cpp
  symbols can rebuild from source via `scripts/build-llama-xcframework.sh`.
- **Two llama.cpp copies** (~+7.7 MB arm64) when both are embedded — inherent to isolation, not tuned in rc.4.
- **Ad-hoc re-sign**: deterministic on a given machine and the checksum is recorded/verified; a consumer
  re-signs embedded frameworks with their own identity at app-sign time regardless.
- esh's dylib is larger than strictly necessary (fuller ggml build); size/perf tuning is out of rc.4 scope.

## Acceptance gate

| Criterion | Result |
|---|---|
| Collision reproduced & understood | ✅ (§1) |
| Native llama surface isolated sufficiently | ✅ rename; dynamic two-level namespace (§4) |
| Standalone EshLlamaCpp still works | ✅ (§6, §8) |
| `LLM.swift` + `EshLlamaCpp` link in one app | ✅ macOS + iOS sim + iOS device + remote tag (§7) |
| No framework / module / duplicate-symbol collision | ✅ |
| Both engines execute in same process | ✅ (§8) |
| iOS Simulator build passes | ✅ |
| iOS device build passes (hardware run) | ✅ build; ⚠️ on-device run not performed — provisioning (§9) |
| macOS build passes | ✅ |
| Same-process sequential runtime proof | ✅ (§8) |
| esh regression suites pass | ✅ (§12) |
| Published remote rc.4 resolves | ✅ (§13) |
| Published binary checksum verified | ✅ (§13) |
| No consumer-side workaround required | ✅ (§14) |
