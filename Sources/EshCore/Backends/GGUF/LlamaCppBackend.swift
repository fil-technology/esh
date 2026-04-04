import Foundation

public struct LlamaCppBackend: InferenceBackend, Sendable {
    public let kind: BackendKind = .gguf
    public let runtimeVersion: String

    public init(runtimeVersion: String = "llama.cpp-cli-v1") {
        self.runtimeVersion = runtimeVersion
    }

    public func loadRuntime(for install: ModelInstall) async throws -> BackendRuntime {
        let modelURL = try locateModelFile(for: install)
        let executableURL = try resolveExecutable()
        return LlamaCppRuntime(
            executableURL: executableURL,
            modelURL: modelURL,
            install: install,
            runtimeVersion: runtimeVersion
        )
    }

    public func makeCompatibilityChecker(for install: ModelInstall) -> CompatibilityChecking {
        LlamaCppCompatibilityChecker(install: install, runtimeVersion: runtimeVersion)
    }

    public func locateModelFile(for install: ModelInstall) throws -> URL {
        let rootURL = URL(fileURLWithPath: install.installPath, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else {
            throw StoreError.invalidManifest("Could not inspect installed GGUF files.")
        }

        let files = enumerator.compactMap { item -> String? in
            guard let fileURL = item as? URL else { return nil }
            return fileURL.path.replacingOccurrences(of: rootURL.path + "/", with: "")
        }
        let selection = ModelFilenameHeuristics.selectGGUFFiles(files)
        guard let selected = selection.selected else {
            throw StoreError.invalidManifest(selection.warning ?? "Could not choose a GGUF file to run.")
        }
        return rootURL.appendingPathComponent(selected)
    }

    func resolveExecutable() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        let candidates = [
            env["ESH_LLAMA_CPP_CLI"],
            env["LLAMA_CPP_CLI"],
            "/opt/homebrew/bin/llama-cli",
            "/usr/local/bin/llama-cli"
        ].compactMap { $0 }

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }

        let output = try? ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/which"),
            arguments: ["llama-cli"]
        )
        if let output, output.exitCode == 0 {
            let path = String(decoding: output.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
        }

        throw StoreError.invalidManifest(
            "llama.cpp runtime not found. Install `llama-cli` or set ESH_LLAMA_CPP_CLI."
        )
    }
}

private struct LlamaCppCompatibilityChecker: CompatibilityChecking, Sendable {
    let install: ModelInstall
    let runtimeVersion: String

    func validate(manifest: CacheManifest) throws {
        throw CompatibilityIssue(reason: "GGUF cache import is not supported by the llama.cpp backend yet.")
    }
}

public final class LlamaCppRuntime: BackendRuntime, @unchecked Sendable {
    public let backend: BackendKind = .gguf
    public let modelID: String

    private let executableURL: URL
    private let modelURL: URL
    private let install: ModelInstall
    private let runtimeVersion: String
    private var currentMetrics: Metrics

    init(
        executableURL: URL,
        modelURL: URL,
        install: ModelInstall,
        runtimeVersion: String,
        metrics: Metrics = .init()
    ) {
        self.executableURL = executableURL
        self.modelURL = modelURL
        self.install = install
        self.runtimeVersion = runtimeVersion
        self.modelID = install.id
        self.currentMetrics = metrics
    }

    public var metrics: Metrics { currentMetrics }

    public func prepare(session: ChatSession) async throws {}

    public func generate(
        session: ChatSession,
        config: GenerationConfig
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let prompt = promptText(for: session)
                    let start = ContinuousClock.now
                    let output = try ProcessRunner.run(
                        executableURL: executableURL,
                        arguments: [
                            "-m", modelURL.path,
                            "-c", "8192",
                            "-n", String(config.maxTokens),
                            "--temp", String(config.temperature),
                            "--no-conversation",
                            "--simple-io",
                            "-p", prompt
                        ]
                    )
                    guard output.exitCode == 0 else {
                        let stderr = String(decoding: output.stderr, as: UTF8.self)
                        throw StoreError.invalidManifest(stderr.isEmpty ? "llama.cpp generation failed." : stderr)
                    }
                    let text = String(decoding: output.stdout, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let elapsed = start.duration(to: .now)
                    let milliseconds = Double(elapsed.components.seconds) * 1_000
                        + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
                    currentMetrics = Metrics(ttftMilliseconds: milliseconds)
                    if !text.isEmpty {
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func exportRuntimeCache() async throws -> CacheSnapshot {
        throw StoreError.invalidManifest("GGUF cache export is not supported by the llama.cpp backend yet.")
    }

    public func importRuntimeCache(_ snapshot: CacheSnapshot) async throws {
        throw StoreError.invalidManifest("GGUF cache import is not supported by the llama.cpp backend yet.")
    }

    public func validateCacheCompatibility(_ manifest: CacheManifest) async throws {
        throw CompatibilityIssue(reason: "GGUF cache compatibility is not supported by the llama.cpp backend yet.")
    }

    public func unload() async {}

    private func promptText(for session: ChatSession) -> String {
        let transcript = session.messages.map { message in
            let role = message.role == .user ? "User" : "Assistant"
            return "\(role): \(message.text)"
        }.joined(separator: "\n")
        return transcript + "\nAssistant:"
    }
}
