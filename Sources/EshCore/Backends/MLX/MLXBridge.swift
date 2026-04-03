import Foundation

public struct MLXBridgeConfiguration: Codable, Hashable, Sendable {
    public var pythonExecutablePath: String?
    public var helperScriptPath: String?
    public var mlxLMVersion: String
    public var mlxVLMVersion: String

    public init(
        pythonExecutablePath: String? = nil,
        helperScriptPath: String? = nil,
        mlxLMVersion: String = "main",
        mlxVLMVersion: String = "0.4.3"
    ) {
        self.pythonExecutablePath = pythonExecutablePath
        self.helperScriptPath = helperScriptPath
        self.mlxLMVersion = mlxLMVersion
        self.mlxVLMVersion = mlxVLMVersion
    }
}

public struct MLXBridge: Sendable {
    public let configuration: MLXBridgeConfiguration

    public init(configuration: MLXBridgeConfiguration = .init()) {
        self.configuration = configuration
    }

    public func run<Request: Encodable, Response: Decodable>(
        command: String,
        request: Request,
        as responseType: Response.Type
    ) throws -> Response {
        let input = try JSONCoding.encoder.encode(request)
        let output = try ProcessRunner.run(
            executableURL: try resolvedPythonExecutable(),
            arguments: [try resolvedHelperScript().path, command],
            stdin: input
        )
        guard output.exitCode == 0 else {
            throw StoreError.invalidManifest(String(decoding: output.stderr, as: UTF8.self))
        }
        return try JSONCoding.decoder.decode(Response.self, from: output.stdout)
    }

    public func resolvedPythonExecutable() throws -> URL {
        if let configured = configuration.pythonExecutablePath {
            return URL(fileURLWithPath: configured)
        }
        if let env = ProcessInfo.processInfo.environment["ESH_PYTHON"] ?? ProcessInfo.processInfo.environment["LLMCACHE_PYTHON"] {
            return URL(fileURLWithPath: env)
        }
        let rootURL = repositoryRootURL()
        let venvPython = rootURL.appendingPathComponent(".venv/bin/python")
        if FileManager.default.isExecutableFile(atPath: venvPython.path) {
            return venvPython
        }
        return URL(fileURLWithPath: "/usr/bin/python3")
    }

    public func resolvedHelperScript() throws -> URL {
        if let configured = configuration.helperScriptPath {
            return URL(fileURLWithPath: configured)
        }
        if let env = ProcessInfo.processInfo.environment["ESH_MLX_VLM_BRIDGE"] ?? ProcessInfo.processInfo.environment["LLMCACHE_MLX_VLM_BRIDGE"] {
            return URL(fileURLWithPath: env)
        }
        let rootURL = repositoryRootURL()
        let helperURL = rootURL.appendingPathComponent("Tools/mlx_vlm_bridge.py")
        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            throw StoreError.notFound("mlx-vlm helper script not found at \(helperURL.path).")
        }
        return helperURL
    }

    private func repositoryRootURL() -> URL {
        let sourceURL = URL(fileURLWithPath: #filePath)
        return sourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
