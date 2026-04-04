import Foundation

public struct InferenceBackendRegistry: Sendable {
    private let mlxBackend: MLXBackend
    private let ggufBackend: LlamaCppBackend

    public init(
        mlxBackend: MLXBackend = .init(),
        ggufBackend: LlamaCppBackend = .init()
    ) {
        self.mlxBackend = mlxBackend
        self.ggufBackend = ggufBackend
    }

    public func backend(for install: ModelInstall) -> any InferenceBackend {
        switch install.spec.backend {
        case .mlx:
            mlxBackend
        case .gguf:
            ggufBackend
        case .onnx:
            mlxBackend
        }
    }
}
