// swift-tools-version: 6.0
import PackageDescription

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
    targets: [
        .target(
            name: "EshCore"
        ),
        .executableTarget(
            name: "esh",
            dependencies: ["EshCore"]
        ),
        .testTarget(
            name: "EshCoreTests",
            dependencies: ["EshCore"]
        )
    ]
)
