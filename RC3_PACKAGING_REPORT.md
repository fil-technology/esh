# esh v2.4.0-rc.3 — Portable Package Dependency Fix (Report)

Status: **rc.3 gate PASSED**. `rc.1` and `rc.2` left immutable.

## 1. Root cause

SwiftPM resolves the **package-level** dependency graph for a consumer regardless of which *products*
that consumer selects. The single root `Package.swift` declared `swift-syntax` (from `603.0.0`) at the
package level — even though only the macOS-only `EshMacRuntime`/`SymbolExtractor` target used it. So every
portable consumer of `EshCore`/`EshRuntime`/`EshLlamaCpp` still had to resolve **swift-syntax 603.x**.

`LLM.swift` 2.x (which LLMHub consumes) requires **swift-syntax 602.x** for its macros
(`.package(url: "…/apple/swift-syntax.git", from: "602.0.0-latest")`, i.e. `>=602.0.0 <603.0.0`). Both
declarations share the SwiftPM identity `swift-syntax`, and `>=603 <604` vs `>=602 <603` are disjoint →
**unsatisfiable resolution**. This was a packaging blocker in esh, not an LLMHub integration bug.

Reproduced deterministically (negative control, no esh involved — just a 603 requirement + LLM.swift):

```
error: Dependencies could not be resolved because root depends on 'llm.swift' 2.0.0..<3.0.0
and root depends on 'swift-syntax' 603.0.0..<604.0.0.
'llm.swift' … practically depends on 'swift-syntax' 602.0.0-latest..<603.0.0 …
```

The M9 work had already removed swift-syntax from the portable *target* (`EshCore`), but that is not enough:
the constraint has to be gone from the *manifest* the consumer resolves.

## 2. Final package structure

Two SwiftPM packages in one repo:

- **Root `Package.swift` — portable, remote-consumable** (`https://github.com/fil-technology/esh.git`)
  - Products: `EshCore`, `EshRuntime`, `EshLlamaCpp` (+ `CLlama` binaryTarget)
  - **`dependencies: []`** — zero external package dependencies
  - `swift-tools-version: 6.0`, platforms macOS 14 / iOS 17
- **`macos/Package.swift` — macOS CLI + dev tooling, NOT published as a product URL**
  - Products: `esh` (executable), `EshMacRuntime` (library)
  - Dependencies: `.package(name: "esh", path: "..")` (portable package, for `EshCore`),
    `swift-syntax` (from `603.0.0`), `TTSMLX`, `mlx-audio-swift` (pinned revision)
  - Build/test with `swift build --package-path macos` / `swift test --package-path macos`
    (the CLI helper scripts and CI were updated to do this).

No source or public-API changes. The macOS runtime and CLI are byte-for-byte the same code, moved under
`macos/Sources` + `macos/Tests`.

## 3. Dependencies removed from the portable graph

Compared to rc.2, the portable consumer graph loses **all** of these (they now resolve only for the
macOS package):

- `swift-syntax` (+ `SwiftParser`, `SwiftSyntaxMacros`, …)
- `TTSMLX`
- `mlx-audio-swift`, `mlx-swift`, `mlx-swift-lm`
- `swift-transformers`, `swift-huggingface`, `swift-jinja`, `yyjson`, `eventsource`
- `swift-crypto`, `swift-asn1`, `swift-collections`, `swift-numerics`, `swift-argument-parser`

Portable consumer now resolves **nothing** external except (for GGUF) a single binaryTarget zip.

## 4. Apple-only dependency graph (`EshRuntime` only)

`swift package show-dependencies` for a consumer depending only on `EshRuntime`:

```
.
└── esh (portable root package)      # No external dependencies found
```

Root package itself: **"No external dependencies found."** Verified in a clean-room build:
`import EshRuntime` compiles with **no swift-syntax module, no llama linked, no EshMacRuntime** in the graph.

Graph: `EshRuntime → EshCore → Apple system frameworks`.

## 5. GGUF dependency graph (`EshRuntime` + `EshLlamaCpp`)

```
EshRuntime → EshCore → Apple frameworks
EshLlamaCpp → EshCore, EshRuntime, CLlama (binaryTarget)
                                   └── llama.xcframework  (remote zip, auto-downloaded)
```

Still **zero external SwiftPM package dependencies**; the only remote fetch is the pinned
`llama.xcframework` release asset. Verified: the remote binaryTarget downloads from the rc.3 release URL and
`EshLlamaCpp` builds and links it (macOS + iOS-simulator slices).

## 6. macOS / CLI dependency graph (`macos/` package)

`esh` (CLI) → `EshCore` (via path package `esh`), `EshMacRuntime`, `TTSMLX`
`EshMacRuntime` → `EshCore`, **`SwiftSyntax`, `SwiftParser`**
Transitively: `TTSMLX → mlx-audio-swift → mlx-swift(-lm), swift-transformers → swift-huggingface,
swift-jinja, swift-collections, swift-crypto → swift-asn1, yyjson, eventsource, swift-numerics,
swift-argument-parser`; plus top-level pinned `mlx-audio-swift`.

**Where SwiftSyntax now lives:** exclusively in `macos/Package.swift` (consumed by `EshMacRuntime`), at
`swift-syntax 603.0.2`. It is absent from the portable root package and from every portable consumer.

## 7. Clean-room `esh + LLM.swift` resolution result

LLMHub-equivalent consumer (`esh` from the **published remote tag** `exact: "2.4.0-rc.3"` + `LLM.swift`
`from: "2.0.0"`):

```
Computed …/fil-technology/esh.git at 2.4.0-rc.3
Computed …/apple/swift-syntax.git at 602.0.0
Working copy of …/eastriverlee/LLM.swift.git resolved at 2.1.0
```

Package.resolved: `esh 2.4.0-rc.3`, `swift-syntax 602.0.0`, `llm.swift 2.1.0` — **resolves, no conflict.**
`EshRuntime` builds in this combined graph; the GGUF variant additionally builds `EshLlamaCpp` linking the
downloaded llama binary.

## 8. Regression results

- Portable root suite (`swift test`): **468 tests / 74 suites passed**.
- macOS suite (`swift test --package-path macos`): **211 tests / 40 suites passed**.
- macOS package `swift build`: **Build complete** (1337 steps); `esh` CLI binary links (121 MB) and runs
  (`esh --help` lists commands).
- Portable root `swift build`: complete (EshCore/EshRuntime/EshLlamaCpp via local Vendor).

## 9. Published rc.3 tag / release

- Tag `v2.4.0-rc.3` → commit `68a61c9`, pushed to `origin`.
- Release: <https://github.com/fil-technology/esh/releases/tag/v2.4.0-rc.3> (prerelease).
- Asset: `llama-xcframework-4a8993735419.zip` (95,933,429 bytes).
- SwiftPM checksum of the **published** asset (re-downloaded from the release URL) =
  `49592e2fa0aff14af87252dfd99384c414a851c83c64d7749aca4569e0dd2289`, matching the manifest. Identical bytes
  to rc.1/rc.2 (llama.cpp pin unchanged @ `4a89937354190cef…`).
- `rc.1` and `rc.2` tags/releases untouched.
- Note (pre-existing, out of scope): the `Package macOS Release` CI job fails at the "Resolve release
  version" step — identically on rc.1, rc.2, and rc.3, i.e. before any build and unrelated to this split.
  That job packages the macOS *binary* distribution, not the SDK. SDK releases are created manually (as here).

## 10. Can LLMHub resume dogfood without workarounds?

**Yes.** A fresh external app depending on `esh` `exact: "2.4.0-rc.3"` **and** `LLM.swift` 2.x resolves and
builds from the remote tag with `swift-syntax` at 602.x — no version pin, no path/commit dependency, no
resolver hack, no change to the LLM.swift dependency, and the legacy LLM.swift backend is untouched.

## Acceptance gate

| Criterion | Result |
|---|---|
| `esh + LLM.swift` (LLMHub-equivalent) resolves | ✅ swift-syntax 602 |
| `EshRuntime` remote consumer builds | ✅ |
| `EshLlamaCpp` remote consumer builds | ✅ (remote binaryTarget downloaded) |
| SwiftSyntax absent from portable consumer graph | ✅ (only in macos/) |
| macOS runtime/CLI still build | ✅ |
| existing tests remain green | ✅ 468 + 211 |
| no local paths/symlinks required (consumer) | ✅ remote url exact |
| remote `v2.4.0-rc.3` consumed from fresh external app | ✅ |
