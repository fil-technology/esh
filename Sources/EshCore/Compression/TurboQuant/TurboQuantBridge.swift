import Foundation

public struct TurboQuantBridge: Sendable {
    public let configuration: TurboQuantConfiguration

    public init(configuration: TurboQuantConfiguration = .init()) {
        self.configuration = configuration
    }

    public func compress(_ data: Data) throws -> Data {
        try run(subcommand: "turboquant-compress", input: data)
    }

    public func decompress(_ data: Data) throws -> Data {
        try run(subcommand: "turboquant-decompress", input: data)
    }

    private func run(subcommand: String, input: Data) throws -> Data {
        let pythonURL = try resolvePythonExecutable()
        let helperScriptURL = try resolveHelperScript()
        let output = try ProcessRunner.run(
            executableURL: pythonURL,
            arguments: [
                helperScriptURL.path,
                subcommand,
                "--bits", String(configuration.bits),
                "--seed", String(configuration.seed)
            ],
            stdin: input
        )

        guard output.exitCode == 0 else {
            let message = String(decoding: output.stderr, as: UTF8.self)
            throw StoreError.invalidManifest("TurboQuant \(subcommand) failed: \(message)")
        }

        return output.stdout
    }

    private func resolvePythonExecutable() throws -> URL {
        RuntimePathResolver.pythonExecutableURL(
            configuredPath: configuration.pythonExecutablePath,
            environment: ProcessInfo.processInfo.environment,
            executablePath: CommandLine.arguments.first,
            sourceFilePath: #filePath
        )
    }

    private func resolveHelperScript() throws -> URL {
        try RuntimePathResolver.helperScriptURL(
            configuredPath: configuration.helperScriptPath,
            environment: ProcessInfo.processInfo.environment,
            executablePath: CommandLine.arguments.first,
            sourceFilePath: #filePath
        )
    }
}
