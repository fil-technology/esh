import Foundation

public struct EshConfig: Codable, Hashable, Sendable {
    public var defaults: EshDefaultsConfig
    public var engines: EshEnginesConfig
    public var experimental: EshExperimentalConfig

    public init(
        defaults: EshDefaultsConfig = .init(),
        engines: EshEnginesConfig = .init(),
        experimental: EshExperimentalConfig = .init()
    ) {
        self.defaults = defaults
        self.engines = engines
        self.experimental = experimental
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
            case ("defaults", "engine"):
                config.defaults.engine = parseString(value)
            case ("defaults", "model_dir"):
                config.defaults.modelDir = parseString(value)
            case ("defaults", "context_size"):
                config.defaults.contextSize = Int(value) ?? config.defaults.contextSize
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
        [defaults]
        engine = "\(defaults.engine)"
        model_dir = "\(defaults.modelDir)"
        context_size = \(defaults.contextSize)

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
}

public struct EshDefaultsConfig: Codable, Hashable, Sendable {
    public var engine: String
    public var modelDir: String
    public var contextSize: Int

    public init(engine: String = "auto", modelDir: String = "~/.esh/models", contextSize: Int = 8192) {
        self.engine = engine
        self.modelDir = modelDir
        self.contextSize = contextSize
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
