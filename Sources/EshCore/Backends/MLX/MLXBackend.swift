import Foundation

public struct MLXBackend: InferenceBackend, RemoteModelConfigValidating, Sendable {
    public let kind: BackendKind = .mlx
    public let runtimeVersion: String
    private let bridge: MLXBridge
    private let locator: MLXModelLocator
    /// When true, `loadRuntime` returns a persistent, weights-resident worker runtime
    /// (`MLXPersistentRuntime`) instead of the per-request subprocess runtime. Enabled for long-lived
    /// hosts (warm pool / serve / chat); one-shot CLI leaves it off.
    private let persistent: Bool

    public init(
        runtimeVersion: String = "mlx-vlm-0.5.0+mlx-lm-bridge-v3",
        bridge: MLXBridge = .init(),
        locator: MLXModelLocator = .init(),
        persistent: Bool = false
    ) {
        self.runtimeVersion = runtimeVersion
        self.bridge = bridge
        self.locator = locator
        self.persistent = persistent
    }

    public func loadRuntime(for install: ModelInstall) async throws -> BackendRuntime {
        _ = try locator.resolveModelPath(for: install)
        if persistent {
            return try await loadPersistentRuntime(for: install)
        }
        return MLXRuntime(bridge: bridge, install: install)
    }

    private func loadPersistentRuntime(for install: ModelInstall) async throws -> BackendRuntime {
        let environment = ProcessInfo.processInfo.environment
        let pythonURL = RuntimePathResolver.pythonExecutableURL(
            configuredPath: bridge.configuration.pythonExecutablePath,
            environment: environment,
            executablePath: ExecutablePath.resolvedPath,
            sourceFilePath: #filePath
        )
        let bridgeURL = try RuntimePathResolver.helperScriptURL(
            configuredPath: bridge.configuration.helperScriptPath,
            environment: environment,
            executablePath: ExecutablePath.resolvedPath,
            sourceFilePath: #filePath
        )
        let worker = MLXWorkerProcess()
        try await worker.start(
            pythonURL: pythonURL,
            bridgeScriptURL: bridgeURL,
            modelPath: install.installPath,
            modelID: install.id
        )
        let ready = worker.readyInfo ?? .init(loadMilliseconds: 0, memoryBytes: nil)
        return MLXPersistentRuntime(worker: worker, bridge: bridge, install: install, readyInfo: ready)
    }

    public func capabilityReport(for install: ModelInstall) -> BackendCapabilityReport {
        do {
            _ = try locator.resolveModelPath(for: install)
            return BackendCapabilityReport(
                backend: kind,
                runtimeVersion: runtimeVersion,
                ready: true,
                supportedFeatures: [
                    .directInference,
                    .tokenStreaming,
                    .promptCacheBuild,
                    .promptCacheLoad,
                    .thinkingMode,
                    .kvCacheQuantization
                ],
                unavailableFeatures: [
                    UnavailableBackendFeature(
                        feature: .promptCacheBenchmark,
                        reason: "MLX prompt cache benchmarking is not exposed through the backend capability API yet."
                    ),
                    UnavailableBackendFeature(
                        feature: .responseFormatJsonSchema,
                        reason: "MLX json_schema response_format requires constrained decoding support, which is not exposed yet."
                    )
                ]
            )
        } catch {
            let reason = error.localizedDescription
            return BackendCapabilityReport(
                backend: kind,
                runtimeVersion: runtimeVersion,
                ready: false,
                supportedFeatures: [],
                unavailableFeatures: [
                    .init(feature: .directInference, reason: reason),
                    .init(feature: .tokenStreaming, reason: reason),
                    .init(feature: .promptCacheBuild, reason: reason),
                    .init(feature: .promptCacheLoad, reason: reason),
                    .init(feature: .thinkingMode, reason: reason),
                    .init(feature: .kvCacheQuantization, reason: reason),
                    .init(
                        feature: .responseFormatJsonSchema,
                        reason: "MLX json_schema response_format requires constrained decoding support, which is not exposed yet."
                    )
                ],
                warnings: [reason]
            )
        }
    }

    public func validateChatModel(for install: ModelInstall) throws -> String? {
        let path = try locator.resolveModelPath(for: install)
        let response: MLXModelValidationResponse = try bridge.run(
            command: "mlx-validate-model",
            request: MLXModelValidationRequest(modelPath: path.path),
            as: MLXModelValidationResponse.self
        )
        return response.ok ? nil : response.reason
    }

    public func validateRemoteConfig(jsonText: String) throws -> String? {
        let response: MLXModelValidationResponse = try bridge.run(
            command: "mlx-validate-config",
            request: MLXConfigValidationRequest(configJSON: jsonText),
            as: MLXModelValidationResponse.self
        )
        return response.ok ? nil : response.reason
    }

    public func makeCompatibilityChecker(for install: ModelInstall) -> CompatibilityChecking {
        MLXCompatibilityChecker(
            install: install,
            runtimeVersion: runtimeVersion
        )
    }

}

private struct MLXModelValidationRequest: Codable, Sendable {
    let modelPath: String
}

private struct MLXConfigValidationRequest: Codable, Sendable {
    let configJSON: String
}

private struct MLXModelValidationResponse: Codable, Sendable {
    let ok: Bool
    let reason: String?
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
