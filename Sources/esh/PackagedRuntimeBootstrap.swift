import CryptoKit
import Foundation
import Darwin
import EshCore

enum PackagedRuntimeBootstrap {
    static func configureEnvironmentIfNeeded() throws {
        let environment = ProcessInfo.processInfo.environment
        if environment["ESH_PYTHON"] != nil, environment["ESH_MLX_VLM_BRIDGE"] != nil {
            return
        }

        guard let rootURL = packagedRootURL() else {
            return
        }

        setLlamaEnvironmentIfAvailable(rootURL: rootURL)

        let helperURL = rootURL.appendingPathComponent("share/esh/Tools/mlx_vlm_bridge.py")
        let requirementsURL = rootURL.appendingPathComponent("share/esh/Tools/python-requirements.txt")
        guard FileManager.default.fileExists(atPath: helperURL.path),
              FileManager.default.fileExists(atPath: requirementsURL.path) else {
            return
        }

        let pythonURL = try resolvedPython(for: rootURL, requirementsURL: requirementsURL)
        setRuntimeEnvironment(pythonURL: pythonURL, helperURL: helperURL)
    }

    private static func packagedRootURL() -> URL? {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let binDirectory = executable.deletingLastPathComponent()
        guard binDirectory.lastPathComponent == "bin" else {
            return nil
        }

        let rootURL = binDirectory.deletingLastPathComponent()
        let helperURL = rootURL.appendingPathComponent("share/esh/Tools/mlx_vlm_bridge.py")
        return FileManager.default.fileExists(atPath: helperURL.path) ? rootURL : nil
    }

    private static func resolvedPython(for rootURL: URL, requirementsURL: URL) throws -> URL {
        let bundledPythonURL = rootURL.appendingPathComponent("python/bin/python3")
        if pythonWorks(at: bundledPythonURL) {
            return bundledPythonURL
        }

        let persistenceRoot = PersistenceRoot.default().rootURL
        let runtimeRoot = persistenceRoot.appendingPathComponent("runtime/python", isDirectory: true)
        let runtimePythonURL = runtimeRoot.appendingPathComponent("bin/python3")
        let stampURL = runtimeRoot.appendingPathComponent(".esh-requirements.sha256")
        let requirementsHash = try sha256(of: requirementsURL)

        if !pythonWorks(at: runtimePythonURL) {
            try? FileManager.default.removeItem(at: runtimeRoot)
            try FileManager.default.createDirectory(
                at: runtimeRoot.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try run(executableURL: try bootstrapPythonExecutable(), arguments: ["-m", "venv", runtimeRoot.path])
        }

        let currentStamp = try? String(contentsOf: stampURL, encoding: .utf8)
        if currentStamp?.trimmingCharacters(in: .whitespacesAndNewlines) != requirementsHash {
            try run(executableURL: runtimePythonURL, arguments: ["-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel"])
            try run(executableURL: runtimePythonURL, arguments: ["-m", "pip", "install", "-r", requirementsURL.path])
            try requirementsHash.write(to: stampURL, atomically: true, encoding: .utf8)
        }

        return runtimePythonURL
    }

    private static func pythonWorks(at url: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            return false
        }

        do {
            let output = try ProcessRunner.run(
                executableURL: url,
                arguments: ["-c", "import sys"]
            )
            return output.exitCode == 0
        } catch {
            return false
        }
    }

    private static func bootstrapPythonExecutable() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["ESH_BOOTSTRAP_PYTHON"],
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ].compactMap { $0 }

        for candidate in candidates {
            let url = URL(fileURLWithPath: candidate)
            if pythonWorks(at: url) {
                return url
            }
        }

        let output = try ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["python3", "-c", "import sys; print(sys.executable)"]
        )
        guard output.exitCode == 0,
              let path = String(data: output.stdout, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            throw StoreError.notFound("python3 is required to bootstrap the packaged runtime.")
        }
        return URL(fileURLWithPath: path)
    }

    private static func run(executableURL: URL, arguments: [String]) throws {
        let output = try ProcessRunner.run(executableURL: executableURL, arguments: arguments)
        guard output.exitCode == 0 else {
            let stderr = String(decoding: output.stderr, as: UTF8.self)
            let stdout = String(decoding: output.stdout, as: UTF8.self)
            let message = stderr.isEmpty ? stdout : stderr
            throw StoreError.invalidManifest(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func setRuntimeEnvironment(pythonURL: URL, helperURL: URL) {
        setenv("ESH_PYTHON", pythonURL.path, 1)
        setenv("LLMCACHE_PYTHON", pythonURL.path, 1)
        setenv("ESH_MLX_VLM_BRIDGE", helperURL.path, 1)
        setenv("LLMCACHE_MLX_VLM_BRIDGE", helperURL.path, 1)
    }

    private static func setLlamaEnvironmentIfAvailable(rootURL: URL) {
        let bundledLlamaURL = rootURL.appendingPathComponent("share/esh/bin/llama-cli")
        guard FileManager.default.isExecutableFile(atPath: bundledLlamaURL.path) else {
            return
        }
        setenv("ESH_LLAMA_CPP_CLI", bundledLlamaURL.path, 0)
    }
}
