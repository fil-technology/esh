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
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.1")
    ],
    targets: [
        .target(
            name: "EshCore",
            dependencies: [
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax")
            ]
        ),
        .executableTarget(
            name: "esh",
            dependencies: ["EshCore"]
        ),
        .testTarget(
            name: "EshCoreTests",
            dependencies: ["EshCore"]
        ),
        .testTarget(
            name: "EshUITests",
            dependencies: ["esh"]
        )
    ]
)
