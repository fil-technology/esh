import Foundation

public struct LlamaCppBackend: InferenceBackend, Sendable {
    public let kind: BackendKind = .gguf
    public let runtimeVersion: String
    public static let runtimeNotFoundMessage = "llama.cpp server not found. Install it with `brew install llama.cpp`, or set ESH_LLAMA_CPP_SERVER to your `llama-server` path."
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
        let serverURL = try resolveExecutable()
        // Start a persistent llama-server for this model. It applies the model's own chat template
        // (--jinja) and stops at the model's native end-of-turn, and stays resident (loaded once) for
        // the runtime's lifetime — owned by RuntimeLifecycleManager like the MLX persistent worker.
        let server = try LlamaServerProcess(executableURL: serverURL, modelPath: modelURL.path)
        do {
            try await server.start()
        } catch {
            server.shutdown()
            throw error
        }
        return LlamaServerRuntime(server: server, install: install)
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
        let executable = ExecutablePath.resolvedURL()
        let bundledDir = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("share/esh/bin")

        // Resolve `llama-server`: esh drives GGUF chat through the server's OpenAI endpoint with the
        // model's own chat template (`--jinja`), so multi-turn chat terminates at the model's native
        // end-of-turn. Prefer the bundled, self-contained binary; ESH_LLAMA_CPP_SERVER overrides.
        let explicit = [env["ESH_LLAMA_CPP_SERVER"]].compactMap { $0 }
        for candidate in explicit where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }

        let candidates = [
            bundledDir.appendingPathComponent("llama-server").path,
            "/opt/homebrew/bin/llama-server",
            "/usr/local/bin/llama-server"
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        let output = try? ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/which"),
            arguments: ["llama-server"]
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
