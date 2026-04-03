import Foundation

public struct MLXBackend: InferenceBackend, Sendable {
    public let kind: BackendKind = .mlx
    public let runtimeVersion: String
    private let bridge: MLXBridge
    private let locator: MLXModelLocator

    public init(
        runtimeVersion: String = "mlx-vlm-0.4.3+mlx-lm-bridge-v1",
        bridge: MLXBridge = .init(),
        locator: MLXModelLocator = .init()
    ) {
        self.runtimeVersion = runtimeVersion
        self.bridge = bridge
        self.locator = locator
    }

    public func loadRuntime(for install: ModelInstall) async throws -> BackendRuntime {
        _ = try locator.resolveModelPath(for: install)
        return MLXRuntime(bridge: bridge, install: install)
    }

    public func makeCompatibilityChecker(for install: ModelInstall) -> CompatibilityChecking {
        MLXCompatibilityChecker(
            install: install,
            runtimeVersion: runtimeVersion
        )
    }

}

private struct MLXCompatibilityChecker: CompatibilityChecking, Sendable {
    let install: ModelInstall
    let runtimeVersion: String

    func validate(manifest: CacheManifest) throws {
        guard manifest.backend == .mlx else {
            throw CompatibilityIssue(reason: "Expected MLX cache, found \(manifest.backend.rawValue).")
        }
        guard manifest.modelID == install.id else {
            throw CompatibilityIssue(reason: "Cache model \(manifest.modelID) does not match \(install.id).")
        }
        guard manifest.runtimeVersion == runtimeVersion else {
            throw CompatibilityIssue(reason: "Cache runtime \(manifest.runtimeVersion) does not match \(runtimeVersion).")
        }
        if let tokenizerID = manifest.tokenizerID,
           let installTokenizer = install.spec.tokenizerID,
           tokenizerID != installTokenizer {
            throw CompatibilityIssue(reason: "Tokenizer mismatch: cache \(tokenizerID), model \(installTokenizer).")
        }
    }
}
