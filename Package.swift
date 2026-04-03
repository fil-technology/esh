// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LLMCache",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "LLMCacheCore",
            targets: ["LLMCacheCore"]
        ),
        .executable(
            name: "llmcache",
            targets: ["llmcache"]
        )
    ],
    targets: [
        .target(
            name: "LLMCacheCore"
        ),
        .executableTarget(
            name: "llmcache",
            dependencies: ["LLMCacheCore"]
        ),
        .testTarget(
            name: "LLMCacheCoreTests",
            dependencies: ["LLMCacheCore"]
        )
    ]
)
