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

// esh M7/M10 — the embedded GGUF backend (EshLlamaCpp) links a prebuilt `llama.xcframework`
// (pinned llama.cpp; see scripts/build-llama-xcframework.sh + docs/SDK_PACKAGING.md §llama distribution).
// The binary is never committed (large, platform-built). It is sourced two ways, checked in order:
//   1. Local dev: `Vendor/llama.xcframework` present → link it by path (what the build script produces).
//   2. Production: a pinned release archive via `binaryTarget(url:checksum:)` — set `llamaBinaryURL`
//      to the published zip so a consumer gets `EshLlamaCpp` with no manual build.
// If neither is available, EshLlamaCpp is omitted and the base package (EshCore/EshRuntime) still builds
// everywhere (so a clean checkout / core CI never needs the binary). Module is `llama`.
// Resolve Vendor relative to THIS manifest's location (not the CWD) — xcodebuild evaluates the manifest
// with a CWD that is not the package root, which previously made this check flip to false.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let hasEmbeddedLlama = FileManager.default.fileExists(atPath: packageDir + "/Vendor/llama.xcframework/Info.plist")

// Pinned release archive of Vendor/llama.xcframework (llama.cpp @ 4a89937354190cef5a97baf8eeb17336105eb72d,
// zipped with `COPYFILE_DISABLE=1 ditto -c -k --keepParent`). `llamaBinaryChecksum` is the SwiftPM checksum
// of that exact published zip (`swift package compute-checksum …`). `llamaBinaryURL` points at the GitHub
// Release asset for tag v2.4.0-rc.3, so a fresh remote consumer that adds `EshLlamaCpp` gets the binary with
// no local build, no Vendor/, and no machine-specific paths. The llama.cpp pin is unchanged since rc.1/rc.2,
// so the archive bytes (and therefore the checksum) are identical to the rc.2 asset. A local
// `Vendor/llama.xcframework` (dev) takes precedence over the URL; `ESH_LLAMA_XCFRAMEWORK_URL` can override
// the URL for staging.
let llamaBinaryChecksum = "49592e2fa0aff14af87252dfd99384c414a851c83c64d7749aca4569e0dd2289"
let llamaBinaryDefaultURL = "https://github.com/fil-technology/esh/releases/download/v2.4.0-rc.3/llama-xcframework-4a8993735419.zip"
let llamaBinaryURL = ProcessInfo.processInfo.environment["ESH_LLAMA_XCFRAMEWORK_URL"] ?? llamaBinaryDefaultURL
let useRemoteLlama = !hasEmbeddedLlama && !llamaBinaryURL.isEmpty

// EshLlamaCpp + its binary target, sourced from a local build (dev) or a pinned release archive (prod).
let llamaTargets: [Target] = {
    guard hasEmbeddedLlama || useRemoteLlama else { return [] }
    let cllama: Target = hasEmbeddedLlama
        ? .binaryTarget(name: "CLlama", path: "Vendor/llama.xcframework")
        : .binaryTarget(name: "CLlama", url: llamaBinaryURL, checksum: llamaBinaryChecksum)
    return [cllama, .target(name: "EshLlamaCpp", dependencies: ["EshCore", "EshRuntime", "CLlama"],
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
        )
    ] + llamaTargets
)

if hasEmbeddedLlama || useRemoteLlama {
    package.products.append(.library(name: "EshLlamaCpp", targets: ["EshLlamaCpp"]))
}
