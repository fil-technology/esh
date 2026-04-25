// swift-tools-version: 6.0
import PackageDescription

let quietDebugSwiftSettings: [SwiftSetting] = [
    .unsafeFlags(["-gnone"], .when(configuration: .debug))
]

let package = Package(
    name: "Esh",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "EshCore",
            targets: ["EshCore"]
        ),
        .executable(
            name: "esh",
            targets: ["esh"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.1"),
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
            name: "EshUITests",
            dependencies: ["esh"],
            swiftSettings: quietDebugSwiftSettings
        )
    ]
)
