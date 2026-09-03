import Foundation

public struct EshConfig: Codable, Hashable, Sendable {
    /// Current config schema version. Bump when the schema changes so releases can migrate.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var defaults: EshDefaultsConfig
    public var engines: EshEnginesConfig
    public var experimental: EshExperimentalConfig

    public init(
        schemaVersion: Int = EshConfig.currentSchemaVersion,
        defaults: EshDefaultsConfig = .init(),
        engines: EshEnginesConfig = .init(),
        experimental: EshExperimentalConfig = .init()
    ) {
        self.schemaVersion = schemaVersion
        self.defaults = defaults
        self.engines = engines
        self.experimental = experimental
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, defaults, engines, experimental
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Configs written before schema versioning default to version 1.
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.defaults = try container.decodeIfPresent(EshDefaultsConfig.self, forKey: .defaults) ?? .init()
        self.engines = try container.decodeIfPresent(EshEnginesConfig.self, forKey: .engines) ?? .init()
        self.experimental = try container.decodeIfPresent(EshExperimentalConfig.self, forKey: .experimental) ?? .init()
    }

    public static let `default` = EshConfig()

    public init(tomlText: String) throws {
        var config = EshConfig.default
        var section = ""

        for rawLine in tomlText.components(separatedBy: .newlines) {
            let withoutComment = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let line = withoutComment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
                continue
            }

            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

            switch (section, key) {
            case ("meta", "schema_version"):
                config.schemaVersion = Int(value) ?? config.schemaVersion
            case ("defaults", "engine"):
                config.defaults.engine = parseString(value)
            case ("defaults", "model_dir"):
                config.defaults.modelDir = parseString(value)
            case ("defaults", "context_size"):
                config.defaults.contextSize = Int(value) ?? config.defaults.contextSize
            case ("defaults", "performance_mode"):
                config.defaults.performanceMode = parseString(value)
            case ("defaults", "tts_model"):
                let m = parseString(value)
                config.defaults.ttsModel = m.isEmpty ? nil : m
            case ("defaults", "stt_model"):
                let m = parseString(value)
                config.defaults.sttModel = m.isEmpty ? nil : m
            case ("defaults.capability_models", _):
                // Arbitrary capability-rawValue keys → installed model id. Empty/"auto" is dropped (= Auto).
                // Keys may be quoted in TOML (they contain a dot), so strip quotes from the key too.
                let capKey = parseString(key)
                let m = parseString(value)
                if !capKey.isEmpty, !m.isEmpty, m != "auto" { config.defaults.capabilityModels[capKey] = m }
            case ("engines.llama_cpp", "enabled"):
                config.engines.llamaCpp.enabled = parseBool(value) ?? config.engines.llamaCpp.enabled
            case ("engines.llama_cpp", "binary"):
                config.engines.llamaCpp.binary = parseString(value)
            case ("engines.llama_cpp", "metal"):
                config.engines.llamaCpp.metal = parseBool(value) ?? config.engines.llamaCpp.metal
            case ("engines.mlx", "enabled"):
                config.engines.mlx.enabled = parseBool(value) ?? config.engines.mlx.enabled
            case ("engines.mlx", "python"):
                config.engines.mlx.python = parseString(value)
            case ("experimental", "ollama_adapter"):
                config.experimental.ollamaAdapter = parseBool(value) ?? config.experimental.ollamaAdapter
            case ("experimental", "llamafile"):
                config.experimental.llamafile = parseBool(value) ?? config.experimental.llamafile
            case ("experimental", "transformers"):
                config.experimental.transformers = parseBool(value) ?? config.experimental.transformers
            case ("experimental", "llama_cpp_server"):
                config.experimental.llamaCppServer = parseBool(value) ?? config.experimental.llamaCppServer
            default:
                continue
            }
        }

        self = config
    }

    public var tomlString: String {
        """
        [meta]
        schema_version = \(schemaVersion)

        [defaults]
        engine = "\(defaults.engine)"
        performance_mode = "\(defaults.performanceMode)"
        # model_dir is deprecated: model/asset storage is managed by `esh storage`
        # (see `esh storage show`). This value is retained only for backward compatibility.
        model_dir = "\(defaults.modelDir)"
        context_size = \(defaults.contextSize)
        tts_model = "\(defaults.ttsModel ?? "")"
        stt_model = "\(defaults.sttModel ?? "")"
        \(capabilityModelsSection)
        [engines.llama_cpp]
        enabled = \(formatBool(engines.llamaCpp.enabled))
        binary = "\(engines.llamaCpp.binary)"
        metal = \(formatBool(engines.llamaCpp.metal))

        [engines.mlx]
        enabled = \(formatBool(engines.mlx.enabled))
        python = "\(engines.mlx.python)"

        [experimental]
        ollama_adapter = \(formatBool(experimental.ollamaAdapter))
        llamafile = \(formatBool(experimental.llamafile))
        transformers = \(formatBool(experimental.transformers))
        llama_cpp_server = \(formatBool(experimental.llamaCppServer))

        """
    }

    /// TOML for the per-capability model overrides. Empty when nothing is pinned (all Auto), so a clean
    /// config stays clean. Keys are capability rawValues (e.g. "vector.generate").
    private var capabilityModelsSection: String {
        let pinned = defaults.capabilityModels.filter { !$0.value.isEmpty && $0.value != "auto" }
        guard !pinned.isEmpty else { return "" }
        let rows = pinned.sorted { $0.key < $1.key }
            .map { "\"\($0.key)\" = \"\($0.value)\"" }
            .joined(separator: "\n")
        return "\n[defaults.capability_models]\n\(rows)\n"
    }
}

public struct EshDefaultsConfig: Codable, Hashable, Sendable {
    public var engine: String
    public var modelDir: String
    public var contextSize: Int
    public var performanceMode: String
    /// Preferred speech models (M10). Persisted so `esh audio speak` / `esh audio transcribe` use them
    /// by default and can be switched. nil = use the built-in working default.
    public var ttsModel: String?
    public var sttModel: String?
    /// esh 2.1 — per-capability model overrides (capability rawValue → installed model id). An entry that
    /// is absent or "auto" means Auto (esh resolves the best installed/local model for that capability).
    /// This is the user-facing "which model performs this action" surface, honored at execution time.
    public var capabilityModels: [String: String]

    public init(engine: String = "auto", modelDir: String = "~/.esh/models", contextSize: Int = 8192,
                performanceMode: String = "auto", ttsModel: String? = nil, sttModel: String? = nil,
                capabilityModels: [String: String] = [:]) {
        self.engine = engine
        self.modelDir = modelDir
        self.contextSize = contextSize
        self.performanceMode = performanceMode
        self.ttsModel = ttsModel
        self.sttModel = sttModel
        self.capabilityModels = capabilityModels
    }

    private enum CodingKeys: String, CodingKey {
        case engine, modelDir, contextSize, performanceMode, ttsModel, sttModel, capabilityModels
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.engine = try c.decodeIfPresent(String.self, forKey: .engine) ?? "auto"
        self.modelDir = try c.decodeIfPresent(String.self, forKey: .modelDir) ?? "~/.esh/models"
        self.contextSize = try c.decodeIfPresent(Int.self, forKey: .contextSize) ?? 8192
        self.performanceMode = try c.decodeIfPresent(String.self, forKey: .performanceMode) ?? "auto"
        self.ttsModel = try c.decodeIfPresent(String.self, forKey: .ttsModel)
        self.sttModel = try c.decodeIfPresent(String.self, forKey: .sttModel)
        self.capabilityModels = try c.decodeIfPresent([String: String].self, forKey: .capabilityModels) ?? [:]
    }
}

public struct EshEnginesConfig: Codable, Hashable, Sendable {
    public var llamaCpp: EshLlamaCppConfig
    public var mlx: EshMLXConfig

    public init(llamaCpp: EshLlamaCppConfig = .init(), mlx: EshMLXConfig = .init()) {
        self.llamaCpp = llamaCpp
        self.mlx = mlx
    }
}

public struct EshLlamaCppConfig: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var binary: String
    public var metal: Bool

    public init(enabled: Bool = true, binary: String = "auto", metal: Bool = true) {
        self.enabled = enabled
        self.binary = binary
        self.metal = metal
    }
}

public struct EshMLXConfig: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var python: String

    public init(enabled: Bool = true, python: String = "auto") {
        self.enabled = enabled
        self.python = python
    }
}

public struct EshExperimentalConfig: Codable, Hashable, Sendable {
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

private func parseString(_ value: String) -> String {
    var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
        text.removeFirst()
        text.removeLast()
    }
    return text
}

private func parseBool(_ value: String) -> Bool? {
    switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "true":
        true
    case "false":
        false
    default:
        nil
    }
}

private func formatBool(_ value: Bool) -> String {
    value ? "true" : "false"
}
