import Foundation

public struct LlamaCppBackend: InferenceBackend, Sendable {
    public let kind: BackendKind = .gguf
    public let runtimeVersion: String
    public static let runtimeNotFoundMessage = "llama.cpp runtime not found. Install it with `brew install llama.cpp`, or set ESH_LLAMA_CPP_CLI to your `llama-cli` path."
    private let executableResolver: @Sendable () throws -> URL

    public init(
        runtimeVersion: String = "llama.cpp-cli-v1",
        executableResolver: (@Sendable () throws -> URL)? = nil
    ) {
        self.runtimeVersion = runtimeVersion
        self.executableResolver = executableResolver ?? {
            try LlamaCppBackend.defaultResolveExecutable()
        }
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

    public func validateChatModel(for install: ModelInstall) throws -> String? {
        _ = try locateModelFile(for: install)
        _ = try resolveExecutable()
        return nil
    }

    public func capabilityReport(for install: ModelInstall) -> BackendCapabilityReport {
        var warnings: [String] = []
        var unavailable: [UnavailableBackendFeature] = [
            .init(
                feature: .promptCacheBuild,
                reason: "GGUF cache build is not supported by the llama.cpp backend yet."
            ),
            .init(
                feature: .promptCacheLoad,
                reason: "GGUF cache load is not supported by the llama.cpp backend yet."
            ),
            .init(
                feature: .promptCacheBenchmark,
                reason: "GGUF cache benchmarking hooks are not implemented yet."
            )
        ]

        do {
            _ = try locateModelFile(for: install)
            _ = try resolveExecutable()
        } catch {
            let reason = error.localizedDescription
            warnings.append(reason)
            unavailable.append(.init(feature: .directInference, reason: reason))
            unavailable.append(.init(feature: .tokenStreaming, reason: reason))
            return BackendCapabilityReport(
                backend: kind,
                runtimeVersion: runtimeVersion,
                ready: false,
                supportedFeatures: [],
                unavailableFeatures: unavailable,
                warnings: warnings
            )
        }

        return BackendCapabilityReport(
            backend: kind,
            runtimeVersion: runtimeVersion,
            ready: true,
            supportedFeatures: [
                .directInference,
                .tokenStreaming
            ],
            unavailableFeatures: unavailable
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
        try executableResolver()
    }

    private static func defaultResolveExecutable() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundledCandidate = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("share/esh/bin/llama-cli")
        let candidates = [
            env["ESH_LLAMA_CPP_CLI"],
            env["LLAMA_CPP_CLI"],
            bundledCandidate.path,
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

        throw StoreError.invalidManifest(Self.runtimeNotFoundMessage)
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

    private final class StreamState: @unchecked Sendable {
        let lock = NSLock()
        var stderrData = Data()
        var sawFirstChunk = false
    }

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
                    let process = Process()
                    process.executableURL = executableURL
                    var arguments = [
                        "-m", modelURL.path,
                        "-c", "8192",
                        "-n", String(config.maxTokens),
                        "--temp", String(config.temperature),
                        "--no-conversation",
                        "--simple-io",
                        "-p", prompt
                    ]
                    if let topP = config.topP {
                        arguments.append(contentsOf: ["--top-p", String(topP)])
                    }
                    if let topK = config.topK {
                        arguments.append(contentsOf: ["--top-k", String(topK)])
                    }
                    if let minP = config.minP {
                        arguments.append(contentsOf: ["--min-p", String(minP)])
                    }
                    if let repetitionPenalty = config.repetitionPenalty {
                        arguments.append(contentsOf: ["--repeat-penalty", String(repetitionPenalty)])
                    }
                    if let seed = config.seed {
                        arguments.append(contentsOf: ["--seed", String(seed)])
                    }
                    process.arguments = arguments

                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe

                    let state = StreamState()

                    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        guard !data.isEmpty else { return }
                        let text = String(decoding: data, as: UTF8.self)
                        state.lock.lock()
                        let shouldRecordFirstChunk = !state.sawFirstChunk
                        if shouldRecordFirstChunk {
                            state.sawFirstChunk = true
                        }
                        state.lock.unlock()

                        if shouldRecordFirstChunk {
                            let elapsed = start.duration(to: .now)
                            let milliseconds = Double(elapsed.components.seconds) * 1_000
                                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
                            self.currentMetrics = Metrics(ttftMilliseconds: milliseconds)
                        }

                        if !text.isEmpty {
                            continuation.yield(text)
                        }
                    }

                    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        guard !data.isEmpty else { return }
                        state.lock.lock()
                        state.stderrData.append(data)
                        state.lock.unlock()
                    }

                    process.terminationHandler = { process in
                        stdoutPipe.fileHandleForReading.readabilityHandler = nil
                        stderrPipe.fileHandleForReading.readabilityHandler = nil

                        state.lock.lock()
                        let stderr = state.stderrData
                        let emittedChunk = state.sawFirstChunk
                        state.lock.unlock()

                        if process.terminationStatus == 0 {
                            if !emittedChunk {
                                let elapsed = start.duration(to: .now)
                                let milliseconds = Double(elapsed.components.seconds) * 1_000
                                    + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
                                self.currentMetrics = Metrics(ttftMilliseconds: milliseconds)
                            }
                            continuation.finish()
                            return
                        }

                        let stderrText = String(decoding: stderr, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.finish(throwing: StoreError.invalidManifest(
                            stderrText.isEmpty ? "llama.cpp generation failed." : stderrText
                        ))
                    }

                    continuation.onTermination = { _ in
                        stdoutPipe.fileHandleForReading.readabilityHandler = nil
                        stderrPipe.fileHandleForReading.readabilityHandler = nil
                        if process.isRunning {
                            process.terminate()
                        }
                    }

                    try process.run()
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
        let normalizedSession = PromptSessionNormalizer().normalized(session: session)
        let transcript = normalizedSession.messages.map { message in
            let role = message.role == .user ? "User" : "Assistant"
            return "\(role): \(message.text)"
        }.joined(separator: "\n")
        return transcript + "\nAssistant:"
    }
}
