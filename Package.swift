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
        )
    ],
    // No external package dependencies: the portable SDK graph is EshCore/EshRuntime → Apple system
    // frameworks (and, for EshLlamaCpp, a single binaryTarget). swift-syntax / TTSMLX / mlx-audio are
    // declared only by the macos/ package.
    dependencies: [],
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
            swiftSettings: quietDebugSwiftSettings
        ),
        .testTarget(
            name: "EshMacCapabilitiesTests",
            dependencies: ["EshMacCapabilities"],
            swiftSettings: quietDebugSwiftSettings
        )
    ] + llamaTargets
)

if hasEmbeddedLlama || useRemoteLlama {
    package.products.append(.library(name: "EshLlamaCpp", targets: ["EshLlamaCpp"]))
}
