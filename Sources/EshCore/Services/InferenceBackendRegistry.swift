import Foundation

public struct InferenceBackendRegistry: Sendable {
    private let mlxBackend: MLXBackend
    private let ggufBackend: LlamaCppBackend
    private let appleBackend: AppleBackend

    public init(
        mlxBackend: MLXBackend = .init(),
        ggufBackend: LlamaCppBackend = .init(),
        appleBackend: AppleBackend = .init()
    ) {
        self.mlxBackend = mlxBackend
        self.ggufBackend = ggufBackend
        self.appleBackend = appleBackend
    }

    public func backend(for install: ModelInstall) -> any InferenceBackend {
        switch install.spec.backend {
        case .mlx:
            mlxBackend
        case .gguf:
            ggufBackend
        case .onnx:
            mlxBackend
        case .apple:
            appleBackend
        }
    }
}
