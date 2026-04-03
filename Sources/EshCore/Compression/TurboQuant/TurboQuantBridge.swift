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
        if let configured = configuration.pythonExecutablePath {
            return URL(fileURLWithPath: configured)
        }

        if let envPath = ProcessInfo.processInfo.environment["ESH_PYTHON"] ?? ProcessInfo.processInfo.environment["LLMCACHE_PYTHON"] {
            return URL(fileURLWithPath: envPath)
        }

        let rootURL = repositoryRootURL()
        let venvPython = rootURL.appendingPathComponent(".venv/bin/python")
        if FileManager.default.isExecutableFile(atPath: venvPython.path) {
            return venvPython
        }

        return URL(fileURLWithPath: "/usr/bin/python3")
    }

    private func resolveHelperScript() throws -> URL {
        if let configured = configuration.helperScriptPath {
            return URL(fileURLWithPath: configured)
        }

        if let envPath = ProcessInfo.processInfo.environment["ESH_MLX_VLM_BRIDGE"] ?? ProcessInfo.processInfo.environment["LLMCACHE_MLX_VLM_BRIDGE"] {
            return URL(fileURLWithPath: envPath)
        }

        let rootURL = repositoryRootURL()
        let helperURL = rootURL.appendingPathComponent("Tools/mlx_vlm_bridge.py")
        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            throw StoreError.notFound("mlx-vlm helper script not found at \(helperURL.path). Set ESH_MLX_VLM_BRIDGE to override.")
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
