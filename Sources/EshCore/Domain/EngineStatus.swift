import Foundation

public enum EngineIdentifier: String, Codable, Hashable, Sendable, CaseIterable {
    case llamaCpp = "llama.cpp"
    case mlx
    case llamafile
    case ollama
    case transformers
    case llamaCppServer = "llama.cpp_server"

    public init(cliValue: String) throws {
        let normalized = cliValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "llama.cpp", "llama-cpp", "llama_cpp", "gguf":
            self = .llamaCpp
        case "mlx", "mlx-lm", "mlx_lm":
            self = .mlx
        case "llamafile":
            self = .llamafile
        case "ollama", "ollama_adapter", "ollama-adapter":
            self = .ollama
        case "transformers", "pytorch", "torch":
            self = .transformers
        case "llama.cpp_server", "llama-server", "llama_cpp_server", "llama.cpp-server":
            self = .llamaCppServer
        default:
            throw StoreError.invalidManifest("Unknown engine \(cliValue). Use llama.cpp or mlx.")
        }
    }

    public var displayName: String {
        switch self {
        case .llamaCpp:
            "llama.cpp"
        case .mlx:
            "MLX / mlx-lm"
        case .llamafile:
            "llamafile"
        case .ollama:
            "Ollama"
        case .transformers:
            "Transformers"
        case .llamaCppServer:
            "llama.cpp server"
        }
    }

    public var binaryName: String? {
        switch self {
        case .llamaCpp:
            "llama-cli"
        case .llamafile:
            "llamafile"
        case .ollama:
            "ollama"
        case .llamaCppServer:
            "llama-server"
        case .mlx, .transformers:
            nil
        }
    }
}

public struct EngineStatus: Codable, Hashable, Sendable {
    public var id: EngineIdentifier
    public var name: String
    public var required: Bool
    public var enabled: Bool
    public var installed: Bool
    public var ready: Bool
    public var executablePath: String?
    public var version: String?
    public var notes: [String]
    public var warnings: [String]
    public var suggestedFix: String?

    public init(
        id: EngineIdentifier,
        name: String? = nil,
        required: Bool,
        enabled: Bool,
        installed: Bool,
        ready: Bool,
        executablePath: String? = nil,
        version: String? = nil,
        notes: [String] = [],
        warnings: [String] = [],
        suggestedFix: String? = nil
    ) {
        self.id = id
        self.name = name ?? id.displayName
        self.required = required
        self.enabled = enabled
        self.installed = installed
        self.ready = ready
        self.executablePath = executablePath
        self.version = version
        self.notes = notes
        self.warnings = warnings
        self.suggestedFix = suggestedFix
    }
}

public struct MLXPackageDoctorReport: Codable, Hashable, Sendable {
    public var pythonExecutable: String
    public var mlxVersion: String
    public var mlxLMVersion: String
    public var mlxVLMVersion: String
    public var numpyVersion: String
    public var safetensorsVersion: String

    public init(
        pythonExecutable: String,
        mlxVersion: String,
        mlxLMVersion: String,
        mlxVLMVersion: String,
        numpyVersion: String,
        safetensorsVersion: String
    ) {
        self.pythonExecutable = pythonExecutable
        self.mlxVersion = mlxVersion
        self.mlxLMVersion = mlxLMVersion
        self.mlxVLMVersion = mlxVLMVersion
        self.numpyVersion = numpyVersion
        self.safetensorsVersion = safetensorsVersion
    }
}

public protocol MLXPackageDoctor: Sendable {
    func check() throws -> MLXPackageDoctorReport
}

public struct BridgeMLXPackageDoctor: MLXPackageDoctor {
    private let bridge: MLXBridge

    public init(bridge: MLXBridge = .init()) {
        self.bridge = bridge
    }

    public func check() throws -> MLXPackageDoctorReport {
        let response: BridgeDoctorResponse = try bridge.run(
            command: "doctor",
            request: EmptyDoctorRequest(),
            as: BridgeDoctorResponse.self
        )
        return MLXPackageDoctorReport(
            pythonExecutable: response.pythonExecutable,
            mlxVersion: response.mlxVersion,
            mlxLMVersion: response.mlxLMVersion,
            mlxVLMVersion: response.mlxVLMVersion,
            numpyVersion: response.numpyVersion,
            safetensorsVersion: response.safetensorsVersion
        )
    }
}

private struct EmptyDoctorRequest: Codable {}

private struct BridgeDoctorResponse: Codable {
    var pythonExecutable: String
    var mlxVersion: String
    var mlxLMVersion: String
    var mlxVLMVersion: String
    var numpyVersion: String
    var safetensorsVersion: String
}
