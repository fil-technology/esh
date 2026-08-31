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
            installedModels: installedModels,
            appleProvider: appleProviderCapability()
        )
    }

    /// Describe Apple Foundation Models as an honest on-device provider in the contract. esh only uses
    /// the on-device system model and never a cloud/PCC path, so on-device is guaranteed and cloud is
    /// not permitted; Apple is never auto-substituted for an explicit downloaded-model request.
    private func appleProviderCapability() -> AppleProviderCapability {
        let status = AppleIntelligenceService().status()
        return AppleProviderCapability(
            available: status.available,
            availability: status.availability.rawValue,
            detail: status.detail,
            onDevice: status.onDevice,
            permitsCloudOrPCC: false,
            neverAutoSelected: true,
            limitations: [
                "no custom sampling parameters (temperature/top-p/top-k/seed are not exposed by the system model)",
                "no native constrained decoding / GBNF (Apple guided generation is a separate mechanism, not wired to EshResponseFormat yet)",
                "text in/out only on this path (no arbitrary attachments)",
                "no explicit tool/function schemas on this path",
                "usage token counts are not reported by the system model"
            ],
            suggestedFix: status.suggestedFix
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
        case .apple:
            ExternalBackendCapability(
                backend: backend,
                supportsDirectInference: true,
                supportsCacheBuild: false,
                supportsCacheLoad: false,
                supportedFeatures: [.directInference],
                unavailableFeatures: [
                    .init(feature: .tokenStreaming, reason: "Apple Foundation Models responses are returned whole on this path (not token-streamed)."),
                    .init(feature: .promptCacheBuild, reason: "Apple Foundation Models does not support prompt caches."),
                    .init(feature: .promptCacheLoad, reason: "Apple Foundation Models does not support prompt caches."),
                    .init(feature: .kvCacheQuantization, reason: "Apple Foundation Models does not expose KV cache controls.")
                ]
            )
        }
    }
}
