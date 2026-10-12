// swift-tools-version: 6.0
import PackageDescription
import Foundation

// esh — PORTABLE SDK package (v2.4.0-rc.3).
//
// This root manifest is the remote-consumable SwiftPM package. It exposes ONLY the portable products
// (EshCore, EshRuntime, and — when a llama binary is available — EshLlamaCpp) and declares NO external
// package dependencies. That is deliberate: a remote consumer that adds `esh` must not be forced to
// resolve dependencies used only by the macOS CLI / dev tooling (swift-syntax, TTSMLX, mlx-audio).
//
// Why the split (rc.3 root cause): SwiftPM resolves the *package-level* dependency graph regardless of
// which products a consumer selects. When swift-syntax (603.x) was declared here — even though only the
// macOS-only EshMacRuntime/SymbolExtractor used it — every portable consumer inherited that 603.x
// constraint. A consumer that also depends on LLM.swift (→ swift-syntax 602.x) then hit an unsolvable
// resolution conflict. Removing the constraint from the *manifest* (not merely from the target) is the
// only structural fix: those macOS-only targets + their dependencies now live in a separate nested
// package under `macos/` (see macos/Package.swift), which depends back on this one by path for dev/CI.
//
// No `.unsafeFlags` (see rc.2): SwiftPM forbids depending on a versioned remote product that uses unsafe
// flags, which makes the package non-consumable. Kept as an (empty) shared setting so target definitions
// stay uniform.
let quietDebugSwiftSettings: [SwiftSetting] = []

// esh M7/M10 — the embedded GGUF backend (EshLlamaCpp) links a prebuilt `esh_llama.xcframework`
// (pinned llama.cpp; see scripts/build-llama-xcframework.sh + docs/SDK_PACKAGING.md §llama distribution).
// The binary is never committed (large, platform-built). It is sourced two ways, checked in order:
//   1. Local dev: `Vendor/esh_llama.xcframework` present → link it by path (what the build script produces).
//   2. Production: a pinned release archive via `binaryTarget(url:checksum:)` — set `llamaBinaryURL`
//      to the published zip so a consumer gets `EshLlamaCpp` with no manual build.
// If neither is available, EshLlamaCpp is omitted and the base package (EshCore/EshRuntime) still builds
// everywhere (so a clean checkout / core CI never needs the binary). Module is `esh_llama` (rc.4).
// Resolve Vendor relative to THIS manifest's location (not the CWD) — xcodebuild evaluates the manifest
// with a CWD that is not the package root, which previously made this check flip to false.
// rc.4: the embedded artifact is the coexistence-safe, esh-private `esh_llama.xcframework` (framework
// `esh_llama.framework`, Clang module `esh_llama`, install name `@rpath/esh_llama.framework/…`). Renamed from
// the upstream `llama.framework`/`llama` so EshLlamaCpp can be linked into the same app as another llama.cpp
// consumer (e.g. LLM.swift) without framework/module/install-name collisions. See
// scripts/namespace-llama-xcframework.sh + docs/SDK_PACKAGING.md §coexistence.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let hasEmbeddedLlama = FileManager.default.fileExists(atPath: packageDir + "/Vendor/esh_llama.xcframework/Info.plist")

// Pinned release archive of Vendor/esh_llama.xcframework (llama.cpp @ 4a89937354190cef5a97baf8eeb17336105eb72d,
// namespaced to esh_llama by scripts/namespace-llama-xcframework.sh, zipped with
// `COPYFILE_DISABLE=1 ditto -c -k --keepParent`). `llamaBinaryChecksum` is the SwiftPM checksum of that exact
// published zip (`swift package compute-checksum …`). `llamaBinaryURL` points at the GitHub Release asset for
// tag v2.4.0-rc.4, so a fresh remote consumer that adds `EshLlamaCpp` gets the coexistence-safe binary with
// no local build, no Vendor/, and no machine-specific paths. The llama.cpp pin is unchanged since rc.1; only
// the framework/module/install-name were renamed (rc.4), so the checksum differs from the rc.1–rc.3 asset.
// A local `Vendor/esh_llama.xcframework` (dev) takes precedence over the URL; `ESH_LLAMA_XCFRAMEWORK_URL`
// can override the URL for staging.
let llamaBinaryChecksum = "4366e678d655672b6f9e990c1b2a6a23df6982cd063beabced97126d4454717e"
let llamaBinaryDefaultURL = "https://github.com/fil-technology/esh/releases/download/v2.4.0-rc.4/esh-llama-xcframework-4a8993735419.zip"
let llamaBinaryURL = ProcessInfo.processInfo.environment["ESH_LLAMA_XCFRAMEWORK_URL"] ?? llamaBinaryDefaultURL
let useRemoteLlama = !hasEmbeddedLlama && !llamaBinaryURL.isEmpty

// EshLlamaCpp + its binary target, sourced from a local build (dev) or a pinned release archive (prod).
let llamaTargets: [Target] = {
    guard hasEmbeddedLlama || useRemoteLlama else { return [] }
    let cllama: Target = hasEmbeddedLlama
        ? .binaryTarget(name: "EshCLlama", path: "Vendor/esh_llama.xcframework")
        : .binaryTarget(name: "EshCLlama", url: llamaBinaryURL, checksum: llamaBinaryChecksum)
    return [cllama, .target(name: "EshLlamaCpp", dependencies: ["EshCore", "EshRuntime", "EshCLlama"],
                            swiftSettings: quietDebugSwiftSettings)]
}()

let package = Package(
    name: "Esh",
    platforms: [
        .macOS(.v14),
        // iOS support for the portable EshCore contracts/runtime (M1). The Apple Foundation Models
        // path is runtime-gated with `#available(iOS 26, …)`; the deployment floor stays lower so the
        // portable core is usable by a wide range of iOS apps. macOS-only execution (MLX/GGUF/
        // subprocess/servers) lives in the separate macos/ package and is never part of an iOS build.
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "EshCore",
            targets: ["EshCore"]
        ),
        .library(
            name: "EshRuntime",
            targets: ["EshRuntime"]
        ),
        // esh-owned macOS compatibility runtime (v2.4): exposes existing macOS-only capabilities
        // (music/SFX/advanced image edit/diarization) through the SAME public capability facade, with esh
        // owning the runtime lifecycle (install/health/repair/process supervision). Lean by design — depends
        // only on EshCore + EshRuntime (no swift-syntax / TTSMLX), so it never regresses the rc.3/rc.4
        // coexistence. Providers are macOS-only (`#if os(macOS)`); on iOS they report unsupportedOnPlatform.
        .library(
            name: "EshMacCapabilities",
            targets: ["EshMacCapabilities"]
        ),
        // Opt-in native image understanding (VLM) via MLX-Swift. iOS + macOS. Consumers link this only when
        // they want vision understanding; it pulls the mlx-swift graph (see `dependencies`).
        .library(
            name: "EshVision",
            targets: ["EshVision"]
        ),
        // Opt-in native image GENERATION (text->image) via MLX-Swift's StableDiffusion (SD 2.1 base,
        // OpenRAIL-M). macOS (Apple silicon). Consumers link this only when they want on-device image
        // generation; it pulls the same mlx-swift graph as EshVision (no new external packages, no
        // swift-syntax). The model downloads from Hugging Face on first use.
        .library(
            name: "EshImageGen",
            targets: ["EshImageGen"]
        ),
        // Opt-in MLX TEXT backend (v2.4): the `MLXBackend` that drives a Python `mlx-serve` worker
        // (via the shipped `mlx_vlm_bridge.py` + the managed venv's `mlx-lm`). Remote-consumable and
        // lean — depends only on EshCore (no mlx-swift / swift-syntax / TTSMLX): MLX *text* runs in the
        // Python worker, not native Swift. A consumer registers `MLXBackend()` into
        // `EshRuntime.makeDefault(backends:)` and resolves the worker's python + bridge via
        // `EshManagedPythonHost` (EshMacCapabilities). esh keeps backend/worker lifecycle + memory guards.
        .library(
            name: "EshMLXText",
            targets: ["EshMLXText"]
        )
    ],
    // Opt-in heavy multimodal: the ONLY external dependency of the portable package, and only the opt-in
    // `EshVision` product uses it (native MLX-Swift VLM). Its graph is mlx-swift + swift-transformers
    // (jinja/huggingface/collections/crypto/yyjson) — verified to contain NO swift-syntax, so the rc.3/rc.4
    // LLM.swift coexistence is preserved. Text/Create-only consumers link EshCore/EshRuntime and never build
    // this. (Core ML image generation, when added, needs no SwiftPM dependency.)
    dependencies: [
        // fil-technology fork of mlx-swift-examples at upstream 378f2449 with the mlx-swift range widened to
        // admit 0.32.x (upstream caps <0.32). Immutable tag. Provides StableDiffusion (EshImageGen) + MLXMNIST.
        .package(url: "https://github.com/fil-technology/mlx-swift-examples.git", exact: "0.1.0-mlx0.32"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.32.3"),
        // swift-transformers' `Hub` product (already in the resolved graph transitively via mlx-swift-examples,
        // and verified to contain NO swift-syntax). Named directly so EshVision can construct a `HubApi` with
        // offline detection disabled — swift-transformers' NWPathMonitor delivers its first path callback
        // asynchronously, so a fresh process momentarily reports "not connected" and the FIRST model download
        // otherwise fails with a spurious "Offline mode error" on a consumer's first launch. Same version spec
        // as mlx-swift-examples (upToNextMinor 1.0.0) so SwiftPM keeps a single consistent version.
        .package(url: "https://github.com/huggingface/swift-transformers", .upToNextMinor(from: "1.3.0")),
        // swift-huggingface provides `HubClient` (used by EshVision's mlx-swift-lm 3.x VLM loader).
        // Already in the resolved graph transitively (swift-transformers / mlx-swift-lm); declared here
        // so EshVision can reference the `HuggingFace` product directly. Range matches swift-transformers'
        // own pin (`0.8.1..<2.0.0`) to avoid introducing a new resolution constraint. No swift-syntax.
        .package(url: "https://github.com/huggingface/swift-huggingface", "0.8.1"..<"2.0.0"),
        // mlx-swift's `MLX` product. Upstream ml-explore/mlx-swift pinned to 0.32.3 — the floor required by
        // mlx-swift-lm 3.31.4. No fork: mlx 0.32.x's refactored Metal error path is background-safe without the
        // old iOS patch (see docs/research/ios-background-safety-mlx-0.32.md; iOS background validation pending).
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.32.3"),
        // Native, content-preserving INSTRUCT image editing (`image.edit`, InstructPix2Pix) + PhotoMaker identity
        // tier. fil-technology fork pinned to an immutable tag; its mlx-swift range admits 0.32.x. Only the opt-in
        // EshImageGen product links it.
        .package(url: "https://github.com/fil-technology/mlx-swift-image-edit.git", exact: "0.2.1-mlx0.32"),
    ],
    targets: [
        // Portable SDK core (M9): contracts, domain types, routing, model-fit, persistence, download,
        // device profile, and the Apple Foundation Models backend. Builds on every Apple platform and
        // carries NO macOS-only execution infrastructure and NO swift-syntax dependency.
        .target(
            name: "EshCore",
            swiftSettings: quietDebugSwiftSettings
        ),
        // App-facing SDK facade (M3). Portable (iOS + macOS); depends only on EshCore, no macOS-only deps.
        .target(
            name: "EshRuntime",
            dependencies: ["EshCore"],
            swiftSettings: quietDebugSwiftSettings
        ),
        .testTarget(
            name: "EshCoreTests",
            dependencies: ["EshCore"],
            swiftSettings: quietDebugSwiftSettings
        ),
        .testTarget(
            name: "EshRuntimeTests",
            dependencies: ["EshRuntime"],
            swiftSettings: quietDebugSwiftSettings
        ),
        .target(
            name: "EshMacCapabilities",
            dependencies: ["EshCore", "EshRuntime"],
            // esh-owned Python bridge scripts, shipped WITH the SDK so a consumer never supplies a bridge
            // path. `EshManagedPythonHost` resolves them via `Bundle.module`. Mirrored from the repo `Tools/`
            // (canonical for the CLI); keep the two in sync when the bridge changes.
            resources: [.copy("Resources/bridge")],
            swiftSettings: quietDebugSwiftSettings
        ),
        .testTarget(
            name: "EshMacCapabilitiesTests",
            dependencies: ["EshMacCapabilities"],
            swiftSettings: quietDebugSwiftSettings
        ),
        .target(
            name: "EshVision",
            dependencies: [
                "EshCore", "EshRuntime",
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Hub", package: "swift-transformers"),
                // mlx-swift-lm 3.x VLM loading: HF tokenizer (`Tokenizers`) + hub client (`HuggingFace`).
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ],
            swiftSettings: quietDebugSwiftSettings
        ),
        .testTarget(
            name: "EshVisionTests",
            dependencies: ["EshVision"],
            swiftSettings: quietDebugSwiftSettings
        ),
        .target(
            name: "EshImageGen",
            dependencies: [
                "EshCore", "EshRuntime",
                .product(name: "StableDiffusion", package: "mlx-swift-examples"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "Hub", package: "swift-transformers"),
                // Native instruct image edit (`image.edit`): the standalone InstructPix2Pix engine.
                .product(name: "MLXImageEdit", package: "mlx-swift-image-edit"),
            ],
            swiftSettings: quietDebugSwiftSettings
        ),
        .testTarget(
            name: "EshImageGenTests",
            dependencies: ["EshImageGen"],
            swiftSettings: quietDebugSwiftSettings
        ),
        // MLX text backend — Python-worker-driven, EshCore-only (no mlx-swift). macOS only at run time
        // (the providers no-op/report unsupported on iOS); the target itself is portable to compile.
        .target(
            name: "EshMLXText",
            dependencies: ["EshCore"],
            swiftSettings: quietDebugSwiftSettings
        ),
        .testTarget(
            name: "EshMLXTextTests",
            dependencies: ["EshMLXText"],
            swiftSettings: quietDebugSwiftSettings
        )
    ] + llamaTargets
)

if hasEmbeddedLlama || useRemoteLlama {
    package.products.append(.library(name: "EshLlamaCpp", targets: ["EshLlamaCpp"]))
}
