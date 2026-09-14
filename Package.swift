// swift-tools-version: 6.0
import PackageDescription
import Foundation

let quietDebugSwiftSettings: [SwiftSetting] = [
    .unsafeFlags(["-gnone"], .when(configuration: .debug))
]

// esh M7/M10 — the embedded GGUF backend (EshLlamaCpp) links a prebuilt `llama.xcframework`
// (pinned llama.cpp; see scripts/build-llama-xcframework.sh + docs/SDK_PACKAGING.md §llama distribution).
// The binary is never committed (large, platform-built). It is sourced two ways, checked in order:
//   1. Local dev: `Vendor/llama.xcframework` present → link it by path (what the build script produces).
//   2. Production: a pinned release archive via `binaryTarget(url:checksum:)` — set `llamaBinaryURL`
//      to the published zip so a consumer gets `EshLlamaCpp` with no manual build.
// If neither is available, EshLlamaCpp is omitted and the base package (EshCore/EshRuntime/esh) still
// builds everywhere (so a clean checkout / core CI never needs the binary). Module is `llama`.
// Resolve Vendor relative to THIS manifest's location (not the CWD) — xcodebuild evaluates the manifest
// with a CWD that is not the package root, which previously made this check flip to false.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let hasEmbeddedLlama = FileManager.default.fileExists(atPath: packageDir + "/Vendor/llama.xcframework/Info.plist")

// Pinned release archive of Vendor/llama.xcframework (llama.cpp @ 4a89937354190cef5a97baf8eeb17336105eb72d,
// zipped with `COPYFILE_DISABLE=1 ditto -c -k --keepParent`). `llamaBinaryChecksum` is the SwiftPM checksum
// of that exact published zip (`swift package compute-checksum …`). `llamaBinaryURL` points at the GitHub
// Release asset for tag v2.4.0-rc.1, so a fresh remote consumer that adds `EshLlamaCpp` gets the binary with
// no local build, no Vendor/, and no machine-specific paths. A local `Vendor/llama.xcframework` (dev) takes
// precedence over the URL; `ESH_LLAMA_XCFRAMEWORK_URL` can override the URL for staging.
let llamaBinaryChecksum = "49592e2fa0aff14af87252dfd99384c414a851c83c64d7749aca4569e0dd2289"
let llamaBinaryDefaultURL = "https://github.com/fil-technology/esh/releases/download/v2.4.0-rc.1/llama-xcframework-4a8993735419.zip"
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
        // subprocess/servers) is excluded from iOS builds via `#if os(macOS)`.
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
        .executable(
            name: "esh",
            targets: ["esh"]
        )
    ],
    dependencies: [
        // Aligned with the Swift 6.3 toolchain (swift-syntax majors track Swift releases;
        // 603.x == Swift 6.3). Used only by EshMacRuntime/SymbolExtractor.swift (a macOS-only context
        // tool) via the stable SyntaxVisitor API — the portable EshCore no longer depends on it (M9).
        // See docs/SDK_PACKAGING.md and docs/STABILIZATION_BASELINE.md §9.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0"),
        .package(url: "https://github.com/fil-technology/TTSMLX.git", from: "0.3.3"),
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", revision: "c96fe7b8577fb1db5a9987a6582e706acb388a8e")
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
        // macOS-only runtime execution infrastructure (M9): MLX + spawned llama.cpp GGUF server +
        // speech/vision/image capabilities + local HTTP servers + agent/context services + the symbol
        // extractor (swift-syntax). Never part of an iOS build. Depends on the portable EshCore and
        // supplies the macOS backend assembly (`InferenceBackendRegistry.macOS()`).
        .target(
            name: "EshMacRuntime",
            dependencies: [
                "EshCore",
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax")
            ],
            swiftSettings: quietDebugSwiftSettings
        ),
        .executableTarget(
            name: "esh",
            dependencies: [
                "EshCore",
                "EshMacRuntime",
                .product(name: "TTSMLX", package: "TTSMLX")
            ],
            swiftSettings: quietDebugSwiftSettings
        ),
        .testTarget(
            name: "EshCoreTests",
            dependencies: ["EshCore"],
            swiftSettings: quietDebugSwiftSettings
        ),
        .testTarget(
            name: "EshMacRuntimeTests",
            dependencies: ["EshMacRuntime"],
            swiftSettings: quietDebugSwiftSettings
        ),
        .testTarget(
            name: "EshRuntimeTests",
            dependencies: ["EshRuntime"],
            swiftSettings: quietDebugSwiftSettings
        ),
        .testTarget(
            name: "EshUITests",
            dependencies: ["esh"],
            swiftSettings: quietDebugSwiftSettings
        )
    ] + llamaTargets
)

if hasEmbeddedLlama || useRemoteLlama {
    package.products.append(.library(name: "EshLlamaCpp", targets: ["EshLlamaCpp"]))
}
