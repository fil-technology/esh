import Foundation

public struct ModelSupportAssessment: Hashable, Sendable {
    public var isFormatSupported: Bool
    public var isArchitectureSupported: Bool
    public var backendLabel: String
    public var notes: [String]
    public var warnings: [String]

    public init(
        isFormatSupported: Bool,
        isArchitectureSupported: Bool,
        backendLabel: String,
        notes: [String] = [],
        warnings: [String] = []
    ) {
        self.isFormatSupported = isFormatSupported
        self.isArchitectureSupported = isArchitectureSupported
        self.backendLabel = backendLabel
        self.notes = notes
        self.warnings = warnings
    }
}

public struct ModelSupportRegistry: Sendable {
    public init() {}

    public func resolveBackend(
        preference: ModelCheckBackendPreference,
        inferredFormat: ModelFormat
    ) -> BackendKind? {
        if let explicit = preference.resolvedBackend {
            return explicit
        }

        switch inferredFormat {
        case .mlx:
            return .mlx
        case .gguf:
            return .gguf
        case .unknown:
            return nil
        }
    }

    public func assess(
        backend: BackendKind?,
        format: ModelFormat,
        architecture: ModelArchitecture,
        isMultimodal: Bool?,
        isAdapter: Bool = false,
        hasSelectedGGUFFile: Bool
    ) -> ModelSupportAssessment {
        guard let backend else {
            return ModelSupportAssessment(
                isFormatSupported: false,
                isArchitectureSupported: false,
                backendLabel: "auto",
                warnings: ["Could not resolve a backend from the available metadata."]
            )
        }

        switch backend {
        case .mlx:
            let formatSupported = format == .mlx
            var notes = formatSupported ? ["MLX format detected."] : []
            var warnings: [String] = []
            if isAdapter {
                notes.append("LoRA adapter detected; Esh will load the base model and apply the adapter at runtime.")
            }
            if architecture == .unknown {
                warnings.append("Architecture could not be confirmed before download.")
            } else if architecture == .other {
                warnings.append("MLX runtime supports more architectures than the preflight classifier can name; runtime config validation is deferred to load time.")
            }
            return ModelSupportAssessment(
                isFormatSupported: formatSupported,
                isArchitectureSupported: true,
                backendLabel: "MLX",
                notes: notes,
                warnings: warnings
            )
        case .gguf:
            let formatSupported = format == .gguf
            let architectureSupported = [.llama, .qwen, .gemma, .mistral, .phi].contains(architecture)
            var warnings: [String] = []
            if isMultimodal == true {
                warnings.append("Initial GGUF support is text-only. Multimodal GGUF models are not wired yet.")
            }
            if formatSupported && !hasSelectedGGUFFile {
                warnings.append("A GGUF file was detected, but no default runtime file could be selected.")
            }
            return ModelSupportAssessment(
                isFormatSupported: formatSupported,
                isArchitectureSupported: architectureSupported && isMultimodal != true && hasSelectedGGUFFile,
                backendLabel: "GGUF (llama.cpp)",
                notes: formatSupported ? ["GGUF format detected for llama.cpp."] : [],
                warnings: warnings
            )
        case .onnx:
            return ModelSupportAssessment(
                isFormatSupported: false,
                isArchitectureSupported: false,
                backendLabel: "ONNX",
                warnings: ["ONNX model checking is not implemented in this command yet."]
            )
        }
    }
}
