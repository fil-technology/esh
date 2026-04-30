import Foundation

public final class EngineOrchestratorService {
    private let root: PersistenceRoot
    private let environment: [String: String]
    private let configStore: EshConfigStore
    private let mlxDoctor: any MLXPackageDoctor
    private let defaultSearchPaths: [String]

    public init(
        root: PersistenceRoot = .default(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        configStore: EshConfigStore? = nil,
        mlxDoctor: any MLXPackageDoctor = BridgeMLXPackageDoctor(),
        defaultSearchPaths: [String] = ["/opt/homebrew/bin", "/usr/local/bin"]
    ) {
        self.root = root
        self.environment = environment
        self.configStore = configStore ?? EshConfigStore(root: root)
        self.mlxDoctor = mlxDoctor
        self.defaultSearchPaths = defaultSearchPaths
    }

    public func listEngines(config: EshConfig? = nil) throws -> [EngineStatus] {
        let config = try config ?? configStore.load()
        return [
            try status(for: .llamaCpp, config: config),
            try status(for: .mlx, config: config),
            try status(for: .llamafile, config: config),
            try status(for: .ollama, config: config),
            try status(for: .transformers, config: config),
            try status(for: .llamaCppServer, config: config)
        ]
    }

    public func status(for engine: EngineIdentifier, config: EshConfig? = nil) throws -> EngineStatus {
        let config = try config ?? configStore.load()
        switch engine {
        case .llamaCpp:
            return llamaCppStatus(config: config)
        case .mlx:
            return mlxStatus(config: config)
        case .llamafile:
            return binaryStatus(
                engine: .llamafile,
                enabled: config.experimental.llamafile,
                required: false,
                binaryName: "llamafile",
                suggestedFix: "Enable [experimental].llamafile and place a llamafile executable on PATH."
            )
        case .ollama:
            return binaryStatus(
                engine: .ollama,
                enabled: config.experimental.ollamaAdapter,
                required: false,
                binaryName: "ollama",
                suggestedFix: "Install Ollama and set experimental.ollama_adapter = true when adapter routing is enabled."
            )
        case .transformers:
            return transformersStatus(config: config)
        case .llamaCppServer:
            return binaryStatus(
                engine: .llamaCppServer,
                enabled: config.experimental.llamaCppServer,
                required: false,
                binaryName: "llama-server",
                suggestedFix: "Install llama.cpp with llama-server and set experimental.llama_cpp_server = true."
            )
        }
    }

    private func llamaCppStatus(config: EshConfig) -> EngineStatus {
        guard config.engines.llamaCpp.enabled else {
            return EngineStatus(
                id: .llamaCpp,
                required: true,
                enabled: false,
                installed: false,
                ready: false,
                notes: ["llama.cpp is disabled in config."],
                suggestedFix: "Set engines.llama_cpp.enabled = true in \(configStore.configURL.path)."
            )
        }

        let configuredBinary = config.engines.llamaCpp.binary
        let executable = resolveLlamaExecutable(configuredBinary: configuredBinary)
        var notes = ["passive detection only; esh does not install llama.cpp automatically."]
        if config.engines.llamaCpp.metal {
            notes.append("Metal acceleration is enabled in config when supported by the runtime.")
        }
        guard let executable else {
            return EngineStatus(
                id: .llamaCpp,
                required: true,
                enabled: true,
                installed: false,
                ready: false,
                notes: notes,
                warnings: ["llama-cli was not found in ESH_LLAMA_CPP_CLI, LLAMA_CPP_CLI, Homebrew paths, or PATH."],
                suggestedFix: "Install it with `brew install llama.cpp`, or set ESH_LLAMA_CPP_CLI to your llama-cli path."
            )
        }
        return EngineStatus(
            id: .llamaCpp,
            required: true,
            enabled: true,
            installed: true,
            ready: true,
            executablePath: executable.path,
            notes: notes
        )
    }

    private func mlxStatus(config: EshConfig) -> EngineStatus {
        guard config.engines.mlx.enabled else {
            return EngineStatus(
                id: .mlx,
                required: true,
                enabled: false,
                installed: false,
                ready: false,
                notes: ["MLX is disabled in config."],
                suggestedFix: "Set engines.mlx.enabled = true in \(configStore.configURL.path)."
            )
        }

        do {
            let report = try mlxDoctor.check()
            return EngineStatus(
                id: .mlx,
                required: true,
                enabled: true,
                installed: true,
                ready: true,
                executablePath: report.pythonExecutable,
                notes: [
                    "Python: \(report.pythonExecutable)",
                    "mlx: \(report.mlxVersion)",
                    "mlx_lm: \(report.mlxLMVersion)",
                    "mlx_vlm: \(report.mlxVLMVersion)",
                    "numpy: \(report.numpyVersion)",
                    "safetensors: \(report.safetensorsVersion)"
                ]
            )
        } catch {
            return EngineStatus(
                id: .mlx,
                required: true,
                enabled: true,
                installed: false,
                ready: false,
                warnings: [error.localizedDescription],
                suggestedFix: "Install MLX bridge dependencies with `python -m pip install -r Tools/python-requirements.txt`, or set ESH_PYTHON to a prepared environment."
            )
        }
    }

    private func transformersStatus(config: EshConfig) -> EngineStatus {
        guard config.experimental.transformers else {
            return EngineStatus(
                id: .transformers,
                required: false,
                enabled: false,
                installed: false,
                ready: false,
                notes: ["Transformers is an optional experimental fallback and is disabled by default."],
                suggestedFix: "Set experimental.transformers = true after installing a Python environment with transformers."
            )
        }

        let python = resolveExecutable(named: "python3")
        return EngineStatus(
            id: .transformers,
            required: false,
            enabled: true,
            installed: python != nil,
            ready: python != nil,
            executablePath: python?.path,
            notes: ["Detection only; esh does not route inference through Transformers yet."],
            suggestedFix: python == nil ? "Install Python and transformers, then keep experimental.transformers = true." : nil
        )
    }

    private func binaryStatus(
        engine: EngineIdentifier,
        enabled: Bool,
        required: Bool,
        binaryName: String,
        suggestedFix: String
    ) -> EngineStatus {
        let executable = resolveExecutable(named: binaryName)
        return EngineStatus(
            id: engine,
            required: required,
            enabled: enabled,
            installed: executable != nil,
            ready: enabled && executable != nil,
            executablePath: executable?.path,
            notes: enabled
                ? ["Detection only; routing for this optional engine is not implemented yet."]
                : ["Optional roadmap adapter disabled in config."],
            suggestedFix: executable == nil || !enabled ? suggestedFix : nil
        )
    }

    private func resolveLlamaExecutable(configuredBinary: String) -> URL? {
        if configuredBinary != "auto" {
            let configured = expandedURL(configuredBinary)
            return isExecutable(configured) ? configured : nil
        }

        for envKey in ["ESH_LLAMA_CPP_CLI", "LLAMA_CPP_CLI"] {
            if let value = environment[envKey], !value.isEmpty {
                let url = expandedURL(value)
                if isExecutable(url) {
                    return url
                }
            }
        }

        for directory in defaultSearchPaths {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("llama-cli")
            if isExecutable(candidate) {
                return candidate
            }
        }

        return resolveExecutable(named: "llama-cli")
    }

    private func resolveExecutable(named name: String) -> URL? {
        let pathValue = environment["PATH"] ?? ""
        for directory in pathValue.split(separator: ":").map(String.init) where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if isExecutable(candidate) {
                return candidate
            }
        }
        return nil
    }

    private func expandedURL(_ path: String) -> URL {
        if path == "~" {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
    }

    private func isExecutable(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }
}
