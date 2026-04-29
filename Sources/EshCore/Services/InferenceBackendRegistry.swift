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

    public func backend(for engine: EngineID) throws -> any InferenceBackend {
        switch engine {
        case .mlx:
            return mlxBackend
        case .llamaCpp:
            return ggufBackend
        case .llamaCppServer, .ollama, .llamafile, .transformers:
            throw StoreError.invalidManifest("\(engine.displayName) is a roadmap adapter and is not enabled as a runtime backend yet.")
        }
    }

    public func engineID(for install: ModelInstall) -> EngineID? {
        switch install.spec.backend {
        case .mlx:
            return .mlx
        case .gguf:
            return .llamaCpp
        case .onnx:
            return nil
        }
    }
}
