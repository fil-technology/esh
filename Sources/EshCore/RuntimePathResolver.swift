import Foundation

enum RuntimePathResolver {
    static func pythonExecutableURL(
        configuredPath: String?,
        environment: [String: String],
        executablePath: String?,
        sourceFilePath: String
    ) -> URL {
        if let configuredPath {
            return URL(fileURLWithPath: configuredPath)
        }

        if let envPath = environment["ESH_PYTHON"] ?? environment["LLMCACHE_PYTHON"] {
            return URL(fileURLWithPath: envPath)
        }

        if let appRoot = appRootURL(environment: environment, executablePath: executablePath) {
            let bundledPython = appRoot.appendingPathComponent("python/bin/python3")
            if FileManager.default.isExecutableFile(atPath: bundledPython.path) {
                return bundledPython
            }
        }

        let repositoryRoot = repositoryRootURL(sourceFilePath: sourceFilePath)
        let venvPython = repositoryRoot.appendingPathComponent(".venv/bin/python")
        if FileManager.default.isExecutableFile(atPath: venvPython.path) {
            return venvPython
        }

        return URL(fileURLWithPath: "/usr/bin/python3")
    }

    static func helperScriptURL(
        configuredPath: String?,
        environment: [String: String],
        executablePath: String?,
        sourceFilePath: String
    ) throws -> URL {
        if let configuredPath {
            return URL(fileURLWithPath: configuredPath)
        }

        if let envPath = environment["ESH_MLX_VLM_BRIDGE"] ?? environment["LLMCACHE_MLX_VLM_BRIDGE"] {
            return URL(fileURLWithPath: envPath)
        }

        if let payloadRoot = payloadRootURL(environment: environment, executablePath: executablePath) {
            let helperURL = payloadRoot.appendingPathComponent("Tools/mlx_vlm_bridge.py")
            if FileManager.default.fileExists(atPath: helperURL.path) {
                return helperURL
            }
        }

        let repositoryRoot = repositoryRootURL(sourceFilePath: sourceFilePath)
        let helperURL = repositoryRoot.appendingPathComponent("Tools/mlx_vlm_bridge.py")
        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            throw StoreError.notFound("mlx-vlm helper script not found at \(helperURL.path). Set ESH_MLX_VLM_BRIDGE to override.")
        }
        return helperURL
    }

    private static func appRootURL(
        environment: [String: String],
        executablePath: String?
    ) -> URL? {
        if let envRoot = environment["ESH_APP_ROOT"], !envRoot.isEmpty {
            return URL(fileURLWithPath: envRoot, isDirectory: true)
        }

        guard let executablePath, !executablePath.isEmpty else {
            return nil
        }

        let executableURL = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
        let binDirectory = executableURL.deletingLastPathComponent()
        guard binDirectory.lastPathComponent == "bin" else {
            return nil
        }

        return binDirectory.deletingLastPathComponent()
    }

    private static func payloadRootURL(
        environment: [String: String],
        executablePath: String?
    ) -> URL? {
        if let envRoot = environment["ESH_PAYLOAD_ROOT"], !envRoot.isEmpty {
            return URL(fileURLWithPath: envRoot, isDirectory: true)
        }

        return appRootURL(environment: environment, executablePath: executablePath)?
            .appendingPathComponent("share/esh", isDirectory: true)
    }

    private static func repositoryRootURL(sourceFilePath: String) -> URL {
        URL(fileURLWithPath: sourceFilePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
