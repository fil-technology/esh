public enum BackendKind: String, Codable, Sendable, CaseIterable {
    case mlx
    case gguf
    case onnx
}
