public enum BackendKind: String, Codable, Sendable, CaseIterable {
    case mlx
    case gguf
    case onnx
    /// Apple Foundation Models on-device system model. Not a downloadable model format like the others
    /// — it is a first-class provider participating in the inference contract. Execution is strictly
    /// on-device (`SystemLanguageModel.default`), never PCC/cloud, and it is never auto-substituted for
    /// an explicit downloaded-model request.
    case apple
}
