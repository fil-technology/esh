import Foundation

public struct ExternalCapabilitiesService: Sendable {
    private let modelStore: ModelStore

    public init(modelStore: ModelStore) {
        self.modelStore = modelStore
    }

    public func describe(toolVersion: String?) throws -> ExternalCapabilitiesResponse {
        let backendCapabilities = BackendKind.allCases.map { backend in
            capability(for: backend)
        }
        let installedModels = try modelStore.listInstalls()
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
            .map { install in
                let backendCapability = capability(for: install.spec.backend)
                return ExternalInstalledModelCapability(
                    id: install.id,
                    displayName: install.spec.displayName,
                    backend: install.spec.backend,
                    source: install.spec.source.reference,
                    variant: install.spec.variant,
                    runtimeVersion: install.runtimeVersion,
                    supportsDirectInference: backendCapability.supportsDirectInference,
                    supportsCacheBuild: backendCapability.supportsCacheBuild,
                    supportsCacheLoad: backendCapability.supportsCacheLoad,
                    supportedFeatures: backendCapability.supportedFeatures,
                    unavailableFeatures: backendCapability.unavailableFeatures
                )
            }

        return ExternalCapabilitiesResponse(
            toolVersion: toolVersion,
            commands: [
                ExternalCommandDescriptor(
                    name: "infer",
                    inputSchema: ExternalInferenceRequest.schemaVersion,
                    outputSchema: ExternalInferenceResponse.schemaVersion,
                    transport: "json"
                ),
                ExternalCommandDescriptor(
                    name: "capabilities",
                    inputSchema: "none",
                    outputSchema: ExternalCapabilitiesResponse.schemaVersion,
                    transport: "json"
                )
            ],
            backends: backendCapabilities,
            installedModels: installedModels
        )
    }

    private func capability(for backend: BackendKind) -> ExternalBackendCapability {
        switch backend {
        case .mlx:
            ExternalBackendCapability(
                backend: backend,
                supportsDirectInference: true,
                supportsCacheBuild: true,
                supportsCacheLoad: true,
                supportedFeatures: [
                    .directInference,
                    .tokenStreaming,
                    .promptCacheBuild,
                    .promptCacheLoad,
                    .thinkingMode,
                    .kvCacheQuantization
                ],
                unavailableFeatures: [
                    .init(
                        feature: .responseFormatJsonSchema,
                        reason: "MLX json_schema response_format requires constrained decoding support, which is not exposed yet."
                    )
                ]
            )
        case .gguf:
            ExternalBackendCapability(
                backend: backend,
                supportsDirectInference: true,
                supportsCacheBuild: false,
                supportsCacheLoad: false,
                supportedFeatures: [
                    .directInference,
                    .tokenStreaming
                ],
                unavailableFeatures: [
                    .init(feature: .promptCacheBuild, reason: "GGUF cache build is not supported by the llama.cpp backend yet."),
                    .init(feature: .promptCacheLoad, reason: "GGUF cache load is not supported by the llama.cpp backend yet."),
                    .init(feature: .promptCacheBenchmark, reason: "GGUF cache benchmarking hooks are not implemented yet.")
                ]
            )
        case .onnx:
            ExternalBackendCapability(
                backend: backend,
                supportsDirectInference: false,
                supportsCacheBuild: false,
                supportsCacheLoad: false,
                unavailableFeatures: [
                    .init(feature: .directInference, reason: "ONNX direct inference is not implemented yet."),
                    .init(feature: .tokenStreaming, reason: "ONNX token streaming is not implemented yet."),
                    .init(feature: .promptCacheBuild, reason: "ONNX prompt cache build is not implemented yet."),
                    .init(feature: .promptCacheLoad, reason: "ONNX prompt cache load is not implemented yet.")
                ]
            )
        }
    }
}
