import Foundation

public enum ModelValidationEnginePreference: String, Codable, Hashable, Sendable {
    case auto
    case llamaCpp = "llama.cpp"
    case mlx

    public init(cliValue: String) throws {
        let normalized = cliValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "auto":
            self = .auto
        case "llama.cpp", "llama-cpp", "llama_cpp", "gguf":
            self = .llamaCpp
        case "mlx", "mlx-lm", "mlx_lm":
            self = .mlx
        default:
            throw StoreError.invalidManifest("Unknown engine \(cliValue). Use auto, llama.cpp, or mlx.")
        }
    }

    public var engineIdentifier: EngineIdentifier? {
        switch self {
        case .auto:
            nil
        case .llamaCpp:
            .llamaCpp
        case .mlx:
            .mlx
        }
    }
}

public struct ModelValidationReport: Codable, Hashable, Sendable {
    public var modelPath: String
    public var format: ModelFormat
    public var compatibleEngines: [EngineIdentifier]
    public var readyEngine: EngineIdentifier?
    public var engineStatuses: [EngineStatus]
    public var notes: [String]
    public var warnings: [String]
    public var suggestedFixes: [String]

    public init(
        modelPath: String,
        format: ModelFormat,
        compatibleEngines: [EngineIdentifier],
        readyEngine: EngineIdentifier?,
        engineStatuses: [EngineStatus],
        notes: [String] = [],
        warnings: [String] = [],
        suggestedFixes: [String] = []
    ) {
        self.modelPath = modelPath
        self.format = format
        self.compatibleEngines = compatibleEngines
        self.readyEngine = readyEngine
        self.engineStatuses = engineStatuses
        self.notes = notes
        self.warnings = warnings
        self.suggestedFixes = suggestedFixes
    }
}
