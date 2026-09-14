// swift-tools-version: 6.0
import PackageDescription

// esh — macOS CLI / dev-tooling package (v2.4.0-rc.3).
//
// This nested package holds everything that is macOS-only and everything that pulls heavy or
// version-constrained external dependencies (swift-syntax, TTSMLX, mlx-audio). It is NOT remote-consumable
// and is never published as a product URL — it exists so the portable root package (../Package.swift) can
// stay dependency-free and remotely consumable alongside packages like LLM.swift.
//
// It depends back on the portable package by path (identity "esh") for EshCore. Path dependencies are used
// only here, for local dev + CI of the macOS runtime and CLI; remote SDK consumers never see this manifest.
//
// Build/test from the repo root with `--package-path macos` (the CLI helper scripts already do this).
let quietDebugSwiftSettings: [SwiftSetting] = []

let package = Package(
    name: "EshMac",
    platforms: [
        // macOS-only. The MLX / spawned llama.cpp server / speech / vision / local-server infrastructure
        // and the CLI run on macOS; iOS builds consume the portable root package instead.
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "esh",
            targets: ["esh"]
        ),
        // Exposed as a library too so the macOS runtime can be embedded/tested independently of the CLI.
        .library(
            name: "EshMacRuntime",
            targets: ["EshMacRuntime"]
        )
    ],
    dependencies: [
        // The portable SDK package, one directory up. Identity is fixed to "esh" via `name:` so it does not
        // depend on the checkout directory's basename.
        .package(name: "esh", path: ".."),
        // Aligned with the Swift 6.3 toolchain (swift-syntax majors track Swift releases; 603.x == Swift 6.3).
        // Used only by EshMacRuntime/SymbolExtractor.swift (a macOS-only context tool) via the stable
        // SyntaxVisitor API. Kept OUT of the portable root package so portable consumers never resolve it
        // (this is the rc.3 fix — see ../Package.swift and docs/SDK_PACKAGING.md).
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.0"),
        .package(url: "https://github.com/fil-technology/TTSMLX.git", from: "0.3.3"),
        // Pinned transitive of TTSMLX: declared top-level to fix the exact revision.
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", revision: "c96fe7b8577fb1db5a9987a6582e706acb388a8e")
    ],
    targets: [
        // macOS-only runtime execution infrastructure (M9): MLX + spawned llama.cpp GGUF server +
        // speech/vision/image capabilities + local HTTP servers + agent/context services + the symbol
        // extractor (swift-syntax). Never part of an iOS build. Depends on the portable EshCore and
        // supplies the macOS backend assembly (`InferenceBackendRegistry.macOS()`).
        .target(
            name: "EshMacRuntime",
            dependencies: [
                .product(name: "EshCore", package: "esh"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax")
            ],
            swiftSettings: quietDebugSwiftSettings
        ),
        .executableTarget(
            name: "esh",
            dependencies: [
                .product(name: "EshCore", package: "esh"),
                "EshMacRuntime",
                .product(name: "TTSMLX", package: "TTSMLX")
            ],
            swiftSettings: quietDebugSwiftSettings
        ),
        .testTarget(
            name: "EshMacRuntimeTests",
            dependencies: ["EshMacRuntime"],
            swiftSettings: quietDebugSwiftSettings
        ),
        .testTarget(
            name: "EshUITests",
            dependencies: ["esh"],
            swiftSettings: quietDebugSwiftSettings
        )
    ]
)
