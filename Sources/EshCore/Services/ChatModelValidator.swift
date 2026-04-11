import Foundation

public struct ChatModelValidator: Sendable {
    private let backendRegistry: InferenceBackendRegistry

    public init(backendRegistry: InferenceBackendRegistry = .init()) {
        self.backendRegistry = backendRegistry
    }

    public func incompatibilityReason(for install: ModelInstall) -> String? {
        let backend = backendRegistry.backend(for: install)
        if let mlxBackend = backend as? MLXBackend {
            return try? mlxBackend.validateChatModel(for: install)
        }
        if let ggufBackend = backend as? LlamaCppBackend {
            return try? ggufBackend.validateChatModel(for: install)
        }
        return nil
    }
}
