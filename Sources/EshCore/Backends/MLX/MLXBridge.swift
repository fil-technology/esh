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
        mlxVLMVersion: String = "0.5.0"
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
        RuntimePathResolver.pythonExecutableURL(
            configuredPath: configuration.pythonExecutablePath,
            environment: ProcessInfo.processInfo.environment,
            executablePath: CommandLine.arguments.first,
            sourceFilePath: #filePath
        )
    }

    public func resolvedHelperScript() throws -> URL {
        try RuntimePathResolver.helperScriptURL(
            configuredPath: configuration.helperScriptPath,
            environment: ProcessInfo.processInfo.environment,
            executablePath: CommandLine.arguments.first,
            sourceFilePath: #filePath
        )
    }
}
