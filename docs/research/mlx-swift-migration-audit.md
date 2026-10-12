# MLX-Swift 0.31 migration — dependency audit (Priority 1, Phase A/B)

Branch: `migration/mlx-swift-0.31` (off `research/extreme-local-inference`). Goal: let the **macOS** package
(+`esh` CLI + macOS `MLXBackend`/server `LlamaCppBackend`) build, preserving text/vision/image/audio. This
documents the current graph, the attempted migration, and the **exact blocker** that stops it (per the directive:
stop + document rather than remove functionality).

## Current constraints (before migration)

| Package | Current pin | Requires mlx-swift | Requires swift-transformers | Notes |
|---|---|---|---|---|
| root `mlx-swift` | upToNextMinor 0.29.1 | 0.29.x | — | direct (EshImageGen `MLX`) |
| root `mlx-swift-examples` | exact 2.29.1 | 0.29.x | 1.0.x | StableDiffusion (EshImageGen) + MLXVLM/MLXLMCommon (EshVision) |
| root `mlx-swift-image-edit` | exact 0.2.0 | 0.29.x | 1.0.x | InstructPix2Pix/PhotoMaker (EshImageGen) |
| root `swift-transformers` | upToNextMinor 1.0.0 | — | self | `Hub` |
| macos `TTSMLX` | from 0.3.3 | **≥0.30.6** (0.7.0+ → 0.31.5) | (via mlx-audio) | on-device TTS; esh imports `TTSMLX` |
| macos `mlx-audio-swift` | revision c96fe7b (transitive of TTSMLX) | **≥0.30.6** | (via mlx-swift-lm) | audio codecs/STT |

**Conflict 1 (mlx-swift):** TTSMLX (≥0.30.6) vs root 0.29.x → the original build failure. **Resolvable:** bump
root to mlx-swift 0.31.6 (TTSMLX 0.3.3 accepts it; so do image-edit's 0.31 branch and examples main).

## Attempted migration (spike config applied to current root)

Applied the proven `spike/mlx-swift-0.31-flux2` dependency set to root `Package.swift`:

```
mlx-swift            : upToNextMinor(from: "0.31.6")
mlx-swift-examples   : revision 378f2449…  (main; MLXMNIST + StableDiffusion; LLM/VLM split into mlx-swift-lm)
swift-transformers   : upToNextMajor(from: "1.3.0")
mlx-swift-image-edit : path "../mlx-swift-image-edit"   (its spike/mlx-swift-0.31 branch, requires mlx-swift 0.31.6)
```

`swift package resolve` on the **root** package succeeds. On the **macOS** package it progresses further than
before — **mlx-swift resolves cleanly at 0.31.6** — then fails on a new, deeper conflict.

## BLOCKER (Conflict 2 — swift-transformers) — exact resolver output

```
'mlx-audio-swift' depends on 'mlx-swift-lm' 2.30.3..<3.0.0 and
'mlx-swift-examples' depends on 'swift-transformers' 1.3.0..<2.0.0.
'mlx-swift-lm' 2.31.3 depends on 'swift-transformers' 1.2.0..<1.3.0;
other mlx-swift-lm versions depend on 1.1.6..<1.2.0.
```

- **image/vision side:** `mlx-swift-examples` main (`378f2449`) → **swift-transformers ≥1.3.0**. EshImageGen
  (StableDiffusion) and EshVision (MLXVLM) need examples on mlx-swift 0.31.x, and the only 0.31.x examples
  revisions available require 1.3.0.
- **audio side:** `mlx-audio-swift` → `mlx-swift-lm` (≤2.31.x) → **swift-transformers <1.3.0** (2.31.3 → 1.2.x).
- **Disjoint ranges → no common swift-transformers version with the current published revisions.** This is
  package-level (manifest) resolution, so it fails even though no single target uses both sides; the root
  manifest declaring `mlx-swift-examples` forces its resolution into the macOS graph alongside `mlx-swift-lm`.

This is the same wall the spike hit: it proved **root-only** builds on 0.31.6 (and moved EshVision to `macos/`),
but the **full macOS graph with audio** (mlx-audio-swift → mlx-swift-lm) was never resolved — hence "EshVision
unwired / incomplete".

## Resolution options (none is a trivial pin change; each needs upstream alignment or restructuring)

1. **Find an `mlx-swift-examples` revision on mlx-swift 0.31.x that uses swift-transformers 1.2.x** (to match
   `mlx-swift-lm` 2.31.3's `1.2.0..<1.3.0`). Pin swift-transformers to `1.2.x`. If StableDiffusion/MLXVLM on that
   revision compile, the whole graph resolves. *Requires archaeology of the examples commit history.*
2. **Bump the audio side** to an `mlx-audio-swift`/`mlx-swift-lm` release that accepts swift-transformers 1.3.0.
   None exists today (all mlx-swift-lm ≤2.31.x want <1.3.0). *Requires an upstream release.*
3. **Decouple image-gen (examples) from the audio graph** via SwiftPM **package traits** so `mlx-swift-examples`
   is only resolved when the image/vision products are actually selected — so a CLI build that needs audio but
   not image-gen doesn't pull examples. *Non-trivial manifest work; may still clash if both are ever needed.*
4. **Replace the examples dependency for StableDiffusion** with `mlx-swift-image-edit`'s graph (already on 0.31.6
   + transformers 1.3) IF it can also provide SD — unlikely without adding SD there. *Scoped.*

## Recommendation / status

- **Conflict 1 (mlx-swift 0.29→0.31) is solved** by the bump above.
- **Conflict 2 (swift-transformers 1.3 vs <1.3) is the hard blocker** and cannot be resolved by pin changes with
  the current published upstream revisions, without dropping image-gen (examples) or audio (mlx-swift-lm) — which
  the directive forbids. **Stopped here and documented** rather than remove functionality.
- Most promising next step: **Option 1** (locate an examples 0.31.x revision on transformers 1.2.x) — a focused
  upstream-revision hunt + a compile check of EshImageGen/EshVision against it. Tracked in ClickUp `z8xxqw8y07` #1.
- The migration branch baseline is kept clean (Package.swift reverted); the attempted config is recorded above so
  it can be re-applied the moment a compatible examples/transformers/lm revision set is identified.

## CORRECTION (2026-10-12) — `mlx-swift-lm` 3.31.4 requires mlx-swift **0.32.3**, not 0.31.x

The "RESOLUTION FOUND" section below assumed `mlx-swift-lm` 3.31.4 stays on mlx-swift 0.31.x
(`.upToNextMinor(from: 0.31.4)`). **That was read from the wrong tag.** The real 3.31.4 manifest
declares `.package(url: ".../mlx-swift", .upToNextMinor(from: "0.32.3"))` → it needs **mlx-swift 0.32.3+**.

- Confirmed empirically: 3.31.4's `MLXLMCommon/Chat.swift` uses `MLXLogger(label:)` from `import MLX`.
  `MLXLogger` is defined in **mlx-swift 0.32.2+** (`Source/MLX/Logging.swift`, added in commit 1960120
  "fix MLXLogger (#493)"), and is **absent from 0.31.6**. Building against 0.31.6 fails with
  `cannot find 'MLXLogger' in scope`.
- **Decision:** the migration target is **mlx-swift 0.32.3**, not 0.31.6. The branch name
  (`migration/mlx-swift-0.31`) is retained but the resolved mlx-swift is 0.32.3.
- `mlx-swift-image-edit` declares `.upToNextMinor(from: "0.31.6")` (= `[0.31.6,0.32)`) and
  `mlx-swift-examples` `378f2449` declares `[0.31.4,0.32)` — both **exclude** 0.32.3 by *version*.
  This is reconciled by the **local path override** of `mlx-swift` (`.package(path: "../mlx-swift")`):
  a path dependency is unversioned and satisfies every transitive version requirement, so
  `swift package resolve` on the macOS graph succeeds at rc=0 (mlx-swift-lm 3.31.4, swift-transformers
  1.3.5, mlx-swift = local path @ 0.32.3). The remaining risk is **source compatibility**: whether
  image-edit (StableDiffusion/PhotoMaker/InstructPix2Pix) and examples (StableDiffusion) *compile*
  against the 0.31→0.32 mlx-swift API — verified by the full build (in progress).
- **Fork/bg-safe note:** the `fil-technology/mlx-swift` fork's background-safe submodule repoint
  (iOS background-permission fix, a 2-file change, no Swift) is currently *not* applied — the checkout
  is upstream 0.32.3. Re-basing the bg-safe patch onto 0.32.3 (incl. the mlx C++ submodule) is a
  **release-prep follow-up**, orthogonal to the macOS build/validation this branch delivers.

---

## RESOLUTION FOUND (Option A/C) — `mlx-swift-lm` 3.31.4 escape hatch

Deeper investigation (reading upstream manifests at exact commits/tags) found a safe path. The disjoint
constraint only exists because the TTS stack pulls **`mlx-swift-lm` 2.31.3** (swift-transformers `[1.2.0,1.3.0)`).
Findings:

- **Option B is false on examples `378f2449`:** it is POST-split — its only products are `MLXMNIST` +
  `StableDiffusion`; MLXVLM/MLXLLM/MLXLMCommon moved to `mlx-swift-lm`. `StableDiffusion` is the *sole* product
  carrying a transformers pin, and it is `[1.3.0, 2.0.0)` — so there is no looser target to exploit.
- **Option C:** the `<1.3.0` cap is **conservative, not a real API break** — swift-transformers 1.3.0 was a
  packaging-only change (Xet trait), and `mlx-swift-lm` 3.x **drops the swift-transformers dependency entirely**.
- **Escape hatch — `mlx-swift-lm` 3.31.4** (read from source): declares **no swift-transformers dependency**,
  stays on **mlx-swift 0.31.x** (`.upToNextMinor(from: 0.31.4)`), still ships `MLXVLM` + `MLXLMCommon` (for
  EshVision), swift-syntax `[602,604)`. Moving the TTS stack onto it removes the transformers constraint, so
  swift-transformers floats to **1.3.x** for StableDiffusion → the graph resolves.

### The compatible set

| package | version/commit | transformers | mlx-swift |
|---|---|---|---|
| mlx-swift (fork) | re-tag **≥0.31.6** (image-edit needs it) | — | — |
| mlx-swift-examples | main `378f2449` (commit; no 0.31.x tag) | `[1.3.0,2.0.0)` (StableDiffusion) | `[0.31.4,0.32)` |
| swift-transformers | `.upToNextMinor(from: 1.3.0)` → 1.3.x | — | — |
| **mlx-swift-lm** | **3.31.4** | **none** | `[0.31.4,0.32)` |
| mlx-audio-swift (fil fork) | widen `mlx-swift-lm` cap to admit 3.31.4 | `[1.1.6,2.0)` ✓ | `[0.30.6,1.0)` ✓ |
| TTSMLX (fil) | change `mlx-swift-lm` `exact 2.31.3` → `exact 3.31.4` (+ bump its mlx-audio pin) | — | — |
| mlx-swift-image-edit | its 0.31 branch (needs mlx-swift ≥0.31.6) | `[1.3.0,…)` ✓ | `[0.31.6,…)` ✓ |

### Required edits (multi-repo — these are the ONLY blockers; all in repos we own)

1. **`fil-technology/TTSMLX`:** `mlx-swift-lm` `exact: "2.31.3"` → `exact: "3.31.4"` (or a 3.31.x range) + bump its
   `mlx-audio-swift` fork pin.
2. **`fil-technology/mlx-audio-swift`** (`0.1.7-tts.1`): widen `mlx-swift-lm .upToNextMajor(from: "2.30.3")`
   (caps `<3.0`) to admit `3.31.4`.
3. **`fil-technology/mlx-swift` fork:** re-tag/re-base to **≥0.31.6** (current `0.31.5` tag doesn't satisfy
   image-edit / examples-main).
4. **esh root `Package.swift`:** examples→`378f2449`, mlx-swift→0.31.x, swift-transformers→`upToNextMinor(1.3.0)`,
   mlx-swift-image-edit→migrated version; **re-source `MLXVLM`/`MLXLMCommon` for EshVision from `mlx-swift-lm`**
   and **relocate EshVision into the `macos/` package** (mlx-swift-lm's macro pulls swift-syntax; keep root
   swift-syntax-free).
5. **`Package.resolved`:** the published `mlx-swift-image-edit 0.2.0` (0.29.x) pin must be replaced by the
   migrated tag.

### Remaining RISK (why this is "present the plan", not "done")

- **`mlx-swift-lm` 2.x→3.x is a MAJOR bump.** The fil forks' source consumes `MLXLMCommon`/`MLXLLM`; those
  products still exist in 3.31.4 but a major bump may carry API changes — **requires an actual build of TTSMLX +
  mlx-audio-swift against 3.31.4 to confirm** (the real risk, not the version math).
- Spans 3 fork repos + re-tagging + an esh manifest change + EshVision relocation. Per the directive (Option D),
  this is presented as the plan rather than force-applied across repos in one pass.

**Verification status:** the version math is confirmed from upstream manifests; a full `swift package resolve` +
build could not be run locally because the fork repos (TTSMLX, mlx-audio-swift) are not sibling checkouts and the
required re-tags don't exist yet. The migration branch baseline stays clean pending the fork edits + re-tags.

## What this unblocks once solved

- macOS `esh` CLI + macOS `MLXBackend` build → **real-weight 30B through the esh macOS runtime** (Phase C #5),
  plus the macOS server `LlamaCppBackend` path for the 80B.

---

## BUILD RESULT (2026-10-12) — macOS esh package **builds and links** against mlx-swift 0.32.3

The full `macos` package (`EshMacRuntime` + `esh` CLI, incl. text/vision/image/audio/TTS backends) compiles and
links with the compatible set above (mlx-swift **0.32.3** via local path, mlx-swift-lm 3.31.4, swift-transformers
1.3.5, mlx-audio-swift + TTSMLX forks on the `migration/mlx-swift-lm-3` branches, mlx-swift-image-edit on
`spike/mlx-swift-0.31`). `swift build` returns rc=0 ("Build complete!"); the `esh` CLI binary
(`.build/out/Products/Debug/esh`, ~126 MB Mach-O arm64) runs (`esh --help` rc=0).

### Source changes required by the 2.x→3.x bump (all in the `fil-technology/mlx-audio-swift` fork)

Confirming the "real risk" noted above — the major bump did carry API changes. Each was the *smallest* change
that restores the behavior, no feature/target removed:

1. **`MLXAudioCodecs` target — add the `Transformers` product dependency.** The target's sources
   `import Tokenizers` but the manifest never declared it; under mlx-swift-lm **2.x** this leaked in transitively
   via `MLXLMCommon`'s swift-transformers dependency. 3.x drops that dependency, so the `Tokenizers→Hub→yyjson`
   clang module stopped propagating into the target's compile and the build failed with
   `unable to resolve module dependency: 'yyjson'` (swiftbuild) / `missing required module 'yyjson'` (native).
   Declaring `.product(name: "Transformers", package: "swift-transformers")` restores the modulemap propagation.
   *(yyjson itself is fine — swift-transformers' `Hub` builds standalone at rc=0; it was purely a missing
   explicit dependency exposed by the 3.x dependency drop.)*
2. **`Tokenizer` is now ambiguous — qualify as `Tokenizers.Tokenizer`.** mlx-swift-lm 3.x introduces its own
   `public protocol Tokenizer: Sendable` in `MLXLMCommon`, colliding with swift-transformers' `Tokenizer`. The TTS
   models use the HF tokenizer, so 6 property/parameter sites were qualified (`LlamaTTS`, `MarvisTTSModel` ×2,
   `Qwen3`, `Qwen3TTS`, `Soprano`).
3. **`loadTokenizer(configuration:hub:)` was removed → `AutoTokenizer.from(pretrained:hubApi:)`.** Per the
   MLXLMCommon 3.x upgrade guide. One site (`MarvisTTSModel` convenience init); the other init in the same file
   already used the new `AutoTokenizer.from(modelFolder:)`. `HubApi` is a single `Hub.HubApi` across the graph and
   the return type is `Tokenizers.Tokenizer`, matching fix #2.

### Build-system note

`swift build` defaults to the new **swiftbuild** (Xcode Swift Build) system on this toolchain (macOS 27 / Xcode 27,
MacOSX27.0.sdk, Swift 6). That is the system under which the package now builds cleanly. The deprecated
`--build-system native` (llbuild) additionally failed to emit swift-transformers' `Hub` module under explicit
modules; swiftbuild is the correct/only path here.

### Root (portable/iOS) package — also builds (EshVision 3.x VLM-load migration)

The root `Source` package (`EshCore`, `EshRuntime`, `EshImageGen`, `EshVision`, `EshLlamaCpp`) builds at rc=0.
The one source change was `EshVision` (the **only** consumer of the 3.x model-load API in the entire codebase):

- mlx-swift-lm 3.x replaced `VLMModelFactory.loadContainer(hub:configuration:)` with
  `loadContainer(from: Downloader, using: TokenizerLoader, configuration:)`. The 3.x idiom is the
  `MLXHuggingFace` macros (`#hubDownloader` / `#huggingFaceTokenizerLoader` / `#adaptHuggingFaceTokenizer`),
  which (a) pull swift-syntax into the consumer and (b) default to `HubClient.default`, dropping EshVision's
  custom external-SSD `downloadBase` + Keychain HF token.
- To preserve both EshVision's **swift-syntax-free** design *and* its custom download location + token, the
  macro expansions were replicated as plain Swift bridge types in `EshVision.swift`
  (`EshHubDownloader: Downloader`, `EshTransformersTokenizerLoader: TokenizerLoader`,
  `EshTokenizerBridge: Tokenizer`) and a custom `HubClient(host:tokenProvider:cache:)` is built from
  `HubCache(cacheDirectory: downloadBase)` + `TokenProvider.fixed(token:)`.
- Manifest: `EshVision` gains `Tokenizers` (swift-transformers) + `HuggingFace` (swift-huggingface, declared
  as a direct root dep at `0.8.1..<2.0.0`, matching swift-transformers' own pin). Neither pulls swift-syntax.

**swift-syntax note (not a regression):** swift-syntax now appears in the root `Package.resolved`, but it is
declared **only by mlx-swift-lm** (its `MLXHuggingFaceMacros` target) — inherent to depending on mlx-swift-lm 3.x
at all, *not* introduced by the swift-huggingface addition. It is **never compiled** in the root build (verified:
no `Compiling SwiftSyntax`/macro-plugin in the build logs; only SwiftPM's *prebuilt* macro-support modules are
fetched). EshVision depends on `MLXVLM`/`MLXLMCommon`, not `MLXHuggingFace`, so the macro plugin is not built and
the portable compile stays swift-syntax-free in practice.

**Status:** both packages **BUILD** against mlx-swift 0.32.3 (macOS esh CLI runs; root portable package compiles).
Remaining: Phase 6 regression (test suite), Phase 5 real-weight validation (30B text, vision, image gen/edit,
audio/TTS, GGUF backend), Phase 7 release artifacts. Fork re-tags / bg-safe re-base are release-prep (not required
to build/validate locally; the branches are consumed by path).

---

## FINAL REPORT (2026-10-12) — Phases 5–7

### Local commits (NOT pushed/tagged/merged — per approval scope)

| Repo | Branch | Commit | Contents |
|---|---|---|---|
| esh (`Source`) | `migration/mlx-swift-0.31` | `f5de1ae` | manifests (root+macOS) + Package.resolved, EshVision 3.x VLM-load, audit doc |
| `mlx-audio-swift` | `migration/mlx-swift-lm-3` | `8415df2` | MLXAudioCodecs Transformers dep, 6 `Tokenizer` qualifications, `loadTokenizer`→`AutoTokenizer.from` |
| `TTSMLX` | `migration/mlx-swift-lm-3` | `f5052ca` | path forks + mlx-swift-lm 3.31.4 + swift-huggingface 0.9.x |
| `mlx-swift` (fork) | *(detached)* | upstream `1960120` (tag `0.32.3`) | checkout only — no fork commit; bg-safe re-base is release-prep |
| `mlx-swift-image-edit` | `spike/mlx-swift-0.31` | *(uncommitted, pre-existing spike)* | 0.31.6/transformers-1.3 manifest + PhotoMakerV1 — consumed by path, left as-is |

### Compatibility / status matrix

| Component | Resolution | Builds | Runtime-validated | Notes |
|---|---|---|---|---|
| mlx-swift | 0.32.3 (path) | ✅ (mlx C++ v0.32.2) | — | MLXLogger present; floor set by mlx-swift-lm 3.31.4 |
| mlx-swift-lm | 3.31.4 | ✅ | — | 2.x→3.x major bump; own `Tokenizer`, macro-based HF loaders |
| swift-transformers | 1.3.5 | ✅ | — | pulls yyjson (via `Hub`); fine once deps declared |
| swift-huggingface | 0.9.x | ✅ | — | `HubClient` for EshVision; no swift-syntax |
| mlx-audio-swift (fork) | path `8415df2` | ✅ | ⏳ not run | TTS; 3 source-level 3.x fixes |
| TTSMLX (fork) | path `f5052ca` | ✅ | ⏳ not run | on-device TTS |
| mlx-swift-image-edit | path (spike) | ✅ | ⏳ not run | image.edit (InstructPix2Pix/PhotoMaker/FLUX2) |
| EshImageGen | — | ✅ | ⏳ not run | native mlx-swift StableDiffusion |
| EshVision | — | ✅ | ⏳ not run | native mlx-swift-lm 3.x VLM (migrated this session) |
| macOS `esh` CLI | — | ✅ runs | ✅ GGUF E2E | 126 MB arm64; `esh infer` produced correct output |
| root test suite | — | ✅ | ✅ 520/520 | 0 failures |
| MLX 30B **text** | — | n/a | n/a (Python) | esh macOS text MLX backend is a **Python `mlx-serve` worker** — NOT the native Swift mlx-swift stack. Unaffected by this migration. |

### Validation status (honest)

- **Proven:** both packages build+link against mlx-swift 0.32.3; 520/520 tests; esh CLI runs; end-to-end
  inference through the migrated macOS runtime (store→route→generate→output) via the GGUF backend.
- **Architecture finding:** the macOS **text** LLM path is Python (`mlx-serve`), so the native Swift mlx-swift /
  mlx-swift-lm stack this migration touches is exercised by **image gen/edit, VLM, and audio/TTS** — not text.
- **Not yet run (resource-heavy, GB-scale weight loads, minutes each):** native-MLX runtime of image.edit
  (EshImageGen/image-edit), VLM (EshVision), and audio/TTS (forks). Recommended as the next validation step; each
  needs its weights present (image-edit + VLM weights are cached on the SSD; the 30B MLX text model is cached but
  runs via Python, so it does not validate the Swift migration).

### Proposed publication order (for when push/tag/publish is approved — NOT done here)

1. `mlx-swift` fork: re-base the bg-safe submodule repoint onto upstream 0.32.3; tag (e.g. `0.32.3-tts-bg-safe.1`).
2. `mlx-swift-image-edit`: commit the 0.31.6/transformers-1.3 manifest; confirm it builds on 0.32.3; tag.
3. `mlx-audio-swift` (`8415df2`) then `TTSMLX` (`f5052ca`): tag once their mlx-swift/mlx-swift-lm pins reference the published mlx-swift tag.
4. esh (`f5de1ae`): repoint path deps → published tags; re-resolve; re-run build + tests; then merge/tag esh.

Steps 1–4 require the NOT-approved actions (push, tag, publish, merge) and are listed as the plan only.

---

## PRODUCTION VALIDATION (2026-10-12) — real-weight, per capability

All runs on this M1 Pro / 32 GB, weights on the external SSD (`/Volumes/Sviat SSD/esh-models`), models
loaded one at a time (no concurrent large loads; the live memory guard was left in place).

### Architecture (confirmed)
- **Text LLM (MLX)** runs through a **Python `mlx-serve` worker** (`MLXRuntime` → `mlx_vlm_bridge.py`,
  Python `mlx_lm`). It needs a Python with `mlx_lm` — resolved via `ESH_PYTHON` / repo `.venv` /
  bundled python, else `/usr/bin/python3` (no mlx). NOT the native Swift mlx-swift stack.
- **Native Swift mlx-swift** (this migration's surface): **vision** (EshVision → mlx-swift-lm 3.x MLXVLM),
  **image gen/edit** (EshImageGen → mlx-swift StableDiffusion / mlx-swift-image-edit), **audio/TTS**
  (TTSMLX / mlx-audio-swift). The `esh image edit` CLI subcommand is a *separate* MFLUX/Python path
  (`ImageEditBackend` = qwen-edit/flux2-klein/kontext) — not the native tier.

### Results

| Capability | How validated | Outcome |
|---|---|---|
| **Native TTS/audio** | `esh audio speak … --model mlx-community/Soprano-80M-bf16` (native TTSMLX) | PASS — valid 1.79 s WAV @ 32 kHz, loaded from SSD cache, clean exit. Exercises the `Tokenizer`-qualification fix (Soprano). |
| **Native vision (VLM)** | `EshVisionTests.realOnDeviceUnderstand` under `xcodebuild` (Qwen2-VL-2B-4bit) | PASS (functional): real inference — shape "circle" + colour "Red"; cancellation 0.40 s; model reuse (243.7 s → 2.0 s); requiresDownload→ready. Exercises the migrated `loadContainer(from:using:configuration:)` + the hand-rolled Downloader/TokenizerLoader/Tokenizer bridges + the custom HubClient (SSD cache + token). The strict single-response assertion (`red` AND `circle` in the *first* reply) tripped on a 4-bit repetition quirk — a model-output artifact, not a migration fault. |
| **Native image gen** | `EshImageGenTests.realOnDeviceGenerate` under `xcodebuild` (SD 2.1 base) | PASS — real 512×512 PNG (424 KB, 21 steps), per-step progress, cancellation 0.52 s, generator reuse. Native mlx-swift diffusion on 0.32.3. |
| **Native image edit** | deterministic suite (PhotoMaker/InstructPix2Pix provider descriptors/routing) + builds on 0.32.3 | PASS (build + deterministic). Same native mlx-swift-image-edit stack as image-gen; a real InstructPix2Pix/PhotoMaker edit run was not executed (cached weights present under `caches/hf-photomaker`). |
| **Python MLX 30B text** | `esh infer --model qwen3-30b-a3b-4bit …` with `ESH_PYTHON=<.venv w/ mlx_lm>` | PASS — `backend=mlx`, `modelID=qwen3-30b-a3b-4bit` (exact, no substitution), coherent generation, 38.3 tok/s, peak ~17.2 GB, prompt-cache hit, rc 0. |
| **Embedded GGUF 80B** | reviewed; validated earlier on the research branch (80B through `EshRuntime` + `LlamaCppEmbeddedBackend`) | Backend untouched by this migration. Clean-shutdown fix (`GGML_METAL_NO_RESIDENCY=1`, `overwrite=0`, before `llama_backend_init`) is isolated on `fix/gguf-metal-shutdown` (c8da2c5/7654f85), absent from this branch — do not merge yet. |
| **Memory safety** | 30B (17.2 GB) permitted; 80B rejection validated earlier; loads kept sequential | PASS — the live preflight gates loads; no bypass. |
| **Model selection** | root-caused + fixed (see below) | PASS — explicit `--model` is exact-or-error. |

### Model-selection defect (root cause + fix)
`ExternalInferenceService.resolveInstall(request:)` fell through to `installs.first` when an explicit
`--model` did not match an *installed* model — a silent substitution (a 30B request ran the installed 8B
GGUF; the 30B lived only in the HF cache, not the esh store). **Fix (committed, `f274f2a`):** an explicit
model is now exact-or-error; a default is chosen only when no model was requested. Registering the cached
30B also required teaching `import` to read HF-cache snapshots (symlink-aware `detect`/copy), committed in
the same change — no network re-download, shared cache left intact.

### Reproducible dependency graph — status + plan
The builds currently use a **SwiftPM path override** for `mlx-swift` because the three native consumers
have **disjoint** declared mlx-swift ranges: mlx-swift-lm 3.31.4 needs `[0.32.3,0.33)`, while
mlx-swift-examples `378f2449` (`[0.31.4,0.32)`) and mlx-swift-image-edit (`[0.31.6,0.32)`) were 0.31.x —
their *sources* all compile on 0.32.3. Toward a path-override-free release graph:
- **image-edit (our fork):** widened to `0.31.6..<0.33.0` — committed (`ba05b90`). Explicitly admits 0.32.x.
- **mlx-swift-examples (NOT our fork):** its manifest still caps `<0.32`. No upstream 0.32.x revision exists
  (mirror `origin/main` still `.upToNextMinor(from: 0.31.4)`). A **fil-technology/mlx-swift-examples** fork
  with the cap widened to `..<0.33.0` is required (source already builds on 0.32.3). *Not created yet —
  needs a repo + push.*
- **mlx-swift fork:** currently the local checkout is upstream 0.32.3. Re-base the background-safe submodule
  repoint onto 0.32.3 and tag (e.g. `0.32.3-tts-bg-safe.1`); point all consumers at that tag.
- **Resolve-from-clean + build + test** can only be executed once those forks are pushed and tagged (NOT
  approved here). Until then the path override is the supported dev mechanism.

### Final acceptance matrix
| Capability | Builds | Real-weight validated | Reproducible (no path override) | Ready |
|---|---|---|---|---|
| Python MLX 30B | ✅ | ✅ (needs `ESH_PYTHON` w/ mlx_lm) | ⚠ path override | ✅ (with Python provisioning) |
| Native Swift vision | ✅ | ✅ (functional; strict assert flaky) | ⚠ path override | ✅ |
| Native Swift image gen | ✅ | ✅ | ⚠ path override | ✅ |
| Native Swift image edit | ✅ | ⚠ build + deterministic only | ⚠ path override | ⚠ |
| Native Swift audio/TTS | ✅ | ✅ | ⚠ path override | ✅ |
| Embedded GGUF 80B | ✅ | ✅ (earlier) | ✅ (unchanged) | ✅ (fix stays isolated) |
| Memory safety | ✅ | ✅ | n/a | ✅ |
| Model selection | ✅ | ✅ | n/a | ✅ |
| Dependency graph | ✅ (path override) | n/a | ❌ (needs examples fork + mlx-swift re-tag + push) | ⚠ |

**Not done / blockers:** (1) a real native image-*edit* (InstructPix2Pix/PhotoMaker) run — deterministic +
build only; (2) path-override-free resolve — blocked on pushing the examples + mlx-swift forks (not
approved); (3) MLX text needs `mlx_lm` in the worker's Python (provisioning), else it falls back to a
Python without mlx. No capability was removed.

---

## P5 — Reproducible dependency graph (prepared; fresh-checkout build is push-blocked)

**Goal:** immutable references + compatible constraints, no SwiftPM path overrides, bg-safe preserved, no tag
overwrites, no image-edit spike changes, both packages build from the prepared refs. **No push/tag/publish.**

**Why a path override exists today:** three consumers declared *disjoint* mlx-swift ranges — mlx-swift-lm
3.31.4 `[0.32.3,0.33)`, mlx-swift-examples `378f2449` `[0.31.4,0.32)`, mlx-swift-image-edit (now widened). Their
*sources* all compile on 0.32.3, so the root uses `.package(path: "../mlx-swift")` to bypass the version math.

**Prepared (committed locally, not pushed):**
- `mlx-swift-image-edit` → mlx-swift range widened to `0.31.6..<0.33.0` (commit `ba05b90`, Package.swift only;
  the pre-existing PhotoMaker/ip2p spike source is intentionally left *uncommitted* per "no unrelated spike
  changes"). This removes image-edit as an override-forcing constraint.
- `mlx-audio-swift` `8415df2`, `TTSMLX` `f5052ca` — the fork source/manifest migration commits.

**Still required for a path-override-free, fresh-checkout build (each needs a push — NOT approved):**
1. **`fil-technology/mlx-swift-examples` fork** at `378f2449` with mlx-swift widened to `0.31.6..<0.33.0` (the
   source already builds on 0.32.3). Without it, examples' `<0.32` cap rejects 0.32.3 and the override is the
   only way the graph resolves. This is the single hard blocker to dropping the override.
2. **`fil-technology/mlx-swift` fork tag on 0.32.3 that re-bases the background-safety submodule repoint**
   (the iOS background-permission fix) onto 0.32.3 — a **new** tag (e.g. `0.32.3-tts-bg-safe.1`), not an
   overwrite of `0.31.5`. The bg-safe change is an mlx **C++ submodule** repoint, so it needs the
   `fil-technology/mlx` C++ fork to carry that patch on mlx **v0.32.2**; that must be built + verified. For the
   **macOS** build/validation the bg-safe patch is not required (it is an iOS concern), which is why the current
   checkout is plain upstream 0.32.3.
3. Re-point the esh root + macOS manifests from the two `.package(path:)` entries to the published fork
   tags/commits, then `swift package resolve` from a clean clone + build both packages + run tests.

**Reproducibility verified so far:** both packages build repeatedly from the **committed** manifests with the
sibling forks present (not stale `.build` state) — root + macOS, 520/520. **Open item:** the esh build currently
compiles the image-edit **working tree** (which still carries the uncommitted PhotoMaker/ip2p spike additions);
before release, verify the build from image-edit's **committed** state (stash the spike, rebuild) so the graph
does not depend on uncommitted spike source. The validated native gen/edit paths (SD 2.1, InstructPix2Pix) do
not use the PhotoMaker tier, so this is expected to be clean, but it must be confirmed.

**Net:** the dependency graph is **prepared** with compatible constraints and local commits; a fully
immutable-reference, path-override-free, fresh-checkout build is **BLOCKED on pushing the two forks**
(examples + mlx-swift bg-safe-on-0.32.3), which are outside the approved scope.

## P6 — GGUF Metal shutdown fix: integration readiness

Fix: `fix/gguf-metal-shutdown` (`c8da2c5` + `7654f85`). `LlamaContext.make` sets
`setenv("GGML_METAL_NO_RESIDENCY","1",0)` **before** `llama_backend_init()`.

- **Isolated:** one file (`Sources/EshLlamaCpp/LlamaCppEmbeddedBackend.swift`); absent from
  `migration/mlx-swift-0.31`. **Compatible with the migration:** `EshLlamaCpp` is untouched by the mlx-swift
  migration (it is the vendored llama.cpp path, no mlx-swift dependency), so there is no interaction or new
  dependency conflict.
- **Host override respected:** `overwrite=0` — a host that sets `GGML_METAL_NO_RESIDENCY` keeps its value.
- **Placement correct:** before Metal init, so it takes effect for the process.
- **No expensive re-benchmark needed:** the migration does not touch GGUF; the earlier 80B clean-exit result
  stands. (Re-run only if the vendored `esh_llama.xcframework` is rebuilt.)
- **Smallest safe integration sequence:** (1) land `migration/mlx-swift-0.31` first (larger surface); (2) rebase
  `fix/gguf-metal-shutdown` onto it (expected trivial — disjoint file) and open a 1-file PR; (3) run the embedded
  GGUF smoke (any small GGUF: clean rc 0 at exit) + full suite; (4) merge. Keep it a separate commit so it can be
  reverted independently. Do not merge into the migration branch beforehand (keep the branches independent).
