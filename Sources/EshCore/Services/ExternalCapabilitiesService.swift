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
                    supportsCacheLoad: backendCapability.supportsCacheLoad
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
                supportsCacheLoad: true
            )
        case .gguf:
            ExternalBackendCapability(
                backend: backend,
                supportsDirectInference: true,
                supportsCacheBuild: false,
                supportsCacheLoad: false
            )
        case .onnx:
            ExternalBackendCapability(
                backend: backend,
                supportsDirectInference: false,
                supportsCacheBuild: false,
                supportsCacheLoad: false
            )
        }
    }
}
