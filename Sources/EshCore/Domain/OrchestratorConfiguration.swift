import Foundation

public struct OrchestratorConfiguration: Codable, Hashable, Sendable {
    public enum DefaultEngine: String, Codable, Hashable, Sendable {
        case auto
        case mlx
        case llamaCpp = "llama.cpp"

        public init?(argument: String) {
            switch argument.lowercased() {
            case "auto":
                self = .auto
            case "mlx", "mlx-lm":
                self = .mlx
            case "llama.cpp", "llama-cpp", "llama_cpp", "gguf":
                self = .llamaCpp
            default:
                return nil
            }
        }
    }

    public struct Defaults: Codable, Hashable, Sendable {
        public var engine: DefaultEngine
        public var modelDirectory: String
        public var contextSize: Int

        public init(
            engine: DefaultEngine = .auto,
            modelDirectory: String = "~/.esh/models",
            contextSize: Int = 8192
        ) {
            self.engine = engine
            self.modelDirectory = modelDirectory
            self.contextSize = contextSize
        }
    }

    public struct EngineSettings: Codable, Hashable, Sendable {
        public var enabled: Bool
        public var binary: String?
        public var metal: Bool?
        public var python: String?

        public init(
            enabled: Bool = true,
            binary: String? = nil,
            metal: Bool? = nil,
            python: String? = nil
        ) {
            self.enabled = enabled
            self.binary = binary
            self.metal = metal
            self.python = python
        }
    }

    public struct Engines: Codable, Hashable, Sendable {
        public var llamaCpp: EngineSettings
        public var mlx: EngineSettings

        public init(
            llamaCpp: EngineSettings = .init(enabled: true, binary: "auto", metal: true),
            mlx: EngineSettings = .init(enabled: true, python: "auto")
        ) {
            self.llamaCpp = llamaCpp
            self.mlx = mlx
        }
    }

    public struct Experimental: Codable, Hashable, Sendable {
        public var ollamaAdapter: Bool
        public var llamafile: Bool
        public var transformers: Bool
        public var llamaCppServer: Bool

        public init(
            ollamaAdapter: Bool = false,
            llamafile: Bool = false,
            transformers: Bool = false,
            llamaCppServer: Bool = false
        ) {
            self.ollamaAdapter = ollamaAdapter
            self.llamafile = llamafile
            self.transformers = transformers
            self.llamaCppServer = llamaCppServer
        }
    }

    public var defaults: Defaults
    public var engines: Engines
    public var experimental: Experimental

    public init(
        defaults: Defaults = .init(),
        engines: Engines = .init(),
        experimental: Experimental = .init()
    ) {
        self.defaults = defaults
        self.engines = engines
        self.experimental = experimental
    }

    public static let `default` = OrchestratorConfiguration()

    public static func parseTOML(_ text: String) throws -> OrchestratorConfiguration {
        var config = OrchestratorConfiguration.default
        var section = ""

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine
                .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !line.isEmpty else { continue }

            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).lowercased()
                continue
            }

            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                throw StoreError.invalidManifest("Invalid config line: \(line)")
            }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

            switch (section, key) {
            case ("defaults", "engine"):
                let parsed = stringValue(value)
                guard let engine = DefaultEngine(argument: parsed) else {
                    throw StoreError.invalidManifest("Unknown default engine: \(parsed)")
                }
                config.defaults.engine = engine
            case ("defaults", "model_dir"):
                config.defaults.modelDirectory = stringValue(value)
            case ("defaults", "context_size"):
                config.defaults.contextSize = try intValue(value)
            case ("engines.llama_cpp", "enabled"):
                config.engines.llamaCpp.enabled = try boolValue(value)
            case ("engines.llama_cpp", "binary"):
                config.engines.llamaCpp.binary = stringValue(value)
            case ("engines.llama_cpp", "metal"):
                config.engines.llamaCpp.metal = try boolValue(value)
            case ("engines.mlx", "enabled"):
                config.engines.mlx.enabled = try boolValue(value)
            case ("engines.mlx", "python"):
                config.engines.mlx.python = stringValue(value)
            case ("experimental", "ollama_adapter"):
                config.experimental.ollamaAdapter = try boolValue(value)
            case ("experimental", "llamafile"):
                config.experimental.llamafile = try boolValue(value)
            case ("experimental", "transformers"):
                config.experimental.transformers = try boolValue(value)
            case ("experimental", "llama_cpp_server"):
                config.experimental.llamaCppServer = try boolValue(value)
            default:
                continue
            }
        }

        return config
    }

    public func tomlString() -> String {
        """
        [defaults]
        engine = "\(defaults.engine.rawValue)"
        model_dir = "\(defaults.modelDirectory)"
        context_size = \(defaults.contextSize)

        [engines.llama_cpp]
        enabled = \(engines.llamaCpp.enabled)
        binary = "\(engines.llamaCpp.binary ?? "auto")"
        metal = \(engines.llamaCpp.metal ?? true)

        [engines.mlx]
        enabled = \(engines.mlx.enabled)
        python = "\(engines.mlx.python ?? "auto")"

        [experimental]
        ollama_adapter = \(experimental.ollamaAdapter)
        llamafile = \(experimental.llamafile)
        transformers = \(experimental.transformers)
        llama_cpp_server = \(experimental.llamaCppServer)
        """
    }

    private static func stringValue(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    private static func boolValue(_ raw: String) throws -> Bool {
        switch stringValue(raw).lowercased() {
        case "true", "yes", "1", "on":
            return true
        case "false", "no", "0", "off":
            return false
        default:
            throw StoreError.invalidManifest("Invalid boolean config value: \(raw)")
        }
    }

    private static func intValue(_ raw: String) throws -> Int {
        guard let value = Int(stringValue(raw)) else {
            throw StoreError.invalidManifest("Invalid integer config value: \(raw)")
        }
        return value
    }
}

public struct OrchestratorConfigurationStore: Sendable {
    public let root: PersistenceRoot

    public init(root: PersistenceRoot = .default()) {
        self.root = root
    }

    public var configURL: URL {
        root.rootURL.appendingPathComponent("config.toml")
    }

    public func load() throws -> OrchestratorConfiguration {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return .default
        }
        let text = try String(contentsOf: configURL, encoding: .utf8)
        return try OrchestratorConfiguration.parseTOML(text)
    }

    public func save(_ configuration: OrchestratorConfiguration) throws {
        try FileManager.default.createDirectory(at: root.rootURL, withIntermediateDirectories: true)
        try configuration.tomlString().write(to: configURL, atomically: true, encoding: .utf8)
    }
}
