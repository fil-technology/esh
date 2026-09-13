// swift-tools-version: 6.0
import PackageDescription
import Foundation

let quietDebugSwiftSettings: [SwiftSetting] = [
    .unsafeFlags(["-gnone"], .when(configuration: .debug))
]

// esh M7 — the embedded GGUF backend (EshLlamaCpp) is included ONLY when a locally-built
// `Vendor/llama.xcframework` is present (see scripts/build-llama-xcframework.sh; the binary is NOT
// committed — it is large and platform-built). This keeps the base package (EshCore/EshRuntime/esh)
// building everywhere without the C/C++ binary, while enabling the in-process llama.cpp backend on
// machines that have built it. The xcframework's own module is `llama` (import llama).
// Resolve Vendor relative to THIS manifest's location (not the CWD) — xcodebuild evaluates the manifest
// with a CWD that is not the package root, which previously made this check flip to false.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let hasEmbeddedLlama = FileManager.default.fileExists(atPath: packageDir + "/Vendor/llama.xcframework/Info.plist")

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
        // 603.x == Swift 6.3). Used only by EshCore/Services/SymbolExtractor.swift via the
        // stable SyntaxVisitor API. See docs/STABILIZATION_BASELINE.md §9 / STABILIZATION_REPORT.md.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0"),
        .package(url: "https://github.com/fil-technology/TTSMLX.git", from: "0.3.3"),
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", revision: "c96fe7b8577fb1db5a9987a6582e706acb388a8e")
    ],
    targets: [
        .target(
            name: "EshCore",
            dependencies: [
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax")
            ],
            swiftSettings: quietDebugSwiftSettings
        ),
        // App-facing SDK facade (M3). Portable (iOS + macOS); depends only on EshCore, no macOS-only deps.
        .target(
            name: "EshRuntime",
            dependencies: ["EshCore"],
            swiftSettings: quietDebugSwiftSettings
        ),
        .executableTarget(
            name: "esh",
            dependencies: [
                "EshCore",
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
            name: "EshRuntimeTests",
            dependencies: ["EshRuntime"],
            swiftSettings: quietDebugSwiftSettings
        ),
        .testTarget(
            name: "EshUITests",
            dependencies: ["esh"],
            swiftSettings: quietDebugSwiftSettings
        )
    ] + (hasEmbeddedLlama ? [
        .binaryTarget(name: "CLlama", path: "Vendor/llama.xcframework"),
        .target(
            name: "EshLlamaCpp",
            dependencies: ["EshCore", "CLlama"],
            swiftSettings: quietDebugSwiftSettings
        )
    ] : [])
)

if hasEmbeddedLlama {
    package.products.append(.library(name: "EshLlamaCpp", targets: ["EshLlamaCpp"]))
}
