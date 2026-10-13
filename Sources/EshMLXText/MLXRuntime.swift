import Foundation
import EshCore

public final class MLXRuntime: BackendRuntime, @unchecked Sendable {
    public let backend: BackendKind = .mlx
    public let modelID: String

    private let bridge: MLXBridge
    private let install: ModelInstall
    private var currentMetrics: Metrics
    private let stateFileURL: URL

    public init(
        bridge: MLXBridge,
        install: ModelInstall,
        stateFileURL: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("esh-runtime-\(UUID().uuidString).json"),
        metrics: Metrics = .init()
    ) {
        self.bridge = bridge
        self.install = install
        self.modelID = install.id
        self.stateFileURL = stateFileURL
        self.currentMetrics = metrics
    }

    public var metrics: Metrics { currentMetrics }

    public func prepare(session: ChatSession) async throws {
        let normalizedSession = PromptSessionNormalizer().normalized(session: session)
        let response: MLXPrepareResponse = try bridge.run(
            command: "mlx-build-cache",
            request: MLXPrepareRequest(
                modelPath: install.installPath,
                modelID: install.id,
                tokenizerID: install.spec.tokenizerID,
                session: normalizedSession,
                stateFilePath: stateFileURL.path,
                kvMode: session.cacheMode ?? .automatic,
                sessionIntent: session.intent ?? .chat,
                triattentionCalibPath: TriAttentionCalibrationLocator().calibrationURL(for: install.id).path,
                triattentionBudget: 2048
            ),
            as: MLXPrepareResponse.self
        )
        currentMetrics = response.metrics
    }

    public func generate(
        session: ChatSession,
        config: GenerationConfig
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            // Holds the spawned subprocess so a consumer-side cancellation (the stream is torn down) can
            // terminate it — otherwise the one-shot `mlx-generate` worker would keep loading/generating in
            // the background after the UI stopped, holding ~weights of RAM until it finished on its own.
            let box = MLXProcessBox()
            let task = Task {
                do {
                    try Task.checkCancellation()
                    let normalizedSession = PromptSessionNormalizer().normalized(session: session)
                    let request = MLXGenerateRequest(
                        modelPath: install.installPath,
                        modelID: install.id,
                        tokenizerID: install.spec.tokenizerID,
                        session: normalizedSession,
                        config: config,
                        stateFilePath: stateFileURL.path,
                        kvMode: session.cacheMode ?? .automatic,
                        sessionIntent: session.intent ?? .chat,
                        triattentionCalibPath: TriAttentionCalibrationLocator().calibrationURL(for: install.id).path,
                        triattentionBudget: 2048
                    )
                    let input = try JSONCoding.encoder.encode(request)
                    let process = Process()
                    process.executableURL = bridgePythonExecutableURL()
                    process.arguments = [try bridgeHelperScriptURL().path, "mlx-generate"]
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    let stdinPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe
                    process.standardInput = stdinPipe
                    box.set(process)                 // register BEFORE run so an early cancel still terminates it
                    try Task.checkCancellation()
                    try process.run()
                    stdinPipe.fileHandleForWriting.write(input)
                    try stdinPipe.fileHandleForWriting.close()

                    for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                        try Task.checkCancellation()   // stop consuming promptly when cancelled
                        guard !line.isEmpty else { continue }
                        let eventData = Data(line.utf8)
                        let event = try JSONCoding.decoder.decode(MLXGenerateEvent.self, from: eventData)
                        switch event.event {
                        case "token":
                            if let text = event.text {
                                continuation.yield(text)
                            }
                        case "done":
                            if let metrics = event.metrics {
                                currentMetrics = metrics
                            }
                        default:
                            continue
                        }
                    }

                    process.waitUntilExit()
                    // A terminated-by-cancel process exits non-zero; surface cancellation, not a parse error.
                    if Task.isCancelled {
                        box.terminate()
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    guard process.terminationStatus == 0 else {
                        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        throw StoreError.invalidManifest(String(decoding: stderr, as: UTF8.self))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    box.terminate()
                    continuation.finish(throwing: CancellationError())
                } catch {
                    box.terminate()   // never leave an orphan worker behind, even on a mid-stream failure
                    continuation.finish(throwing: error)
                }
            }
            // Consumer tore the stream down (cancel or early break) → kill the subprocess and the reader.
            continuation.onTermination = { _ in
                box.terminate()
                task.cancel()
            }
        }
    }

    public func exportRuntimeCache() async throws -> CacheSnapshot {
        let response: MLXExportCacheResponse = try bridge.run(
            command: "mlx-export-cache",
            request: MLXExportCacheRequest(
                modelPath: install.installPath,
                modelID: install.id,
                stateFilePath: stateFileURL.path
            ),
            as: MLXExportCacheResponse.self
        )
        currentMetrics = response.metrics ?? currentMetrics
        return response.snapshot
    }

    public func importRuntimeCache(_ snapshot: CacheSnapshot) async throws {
        let response: MLXImportCacheResponse = try bridge.run(
            command: "mlx-import-cache",
            request: MLXImportCacheRequest(
                modelPath: install.installPath,
                modelID: install.id,
                stateFilePath: stateFileURL.path,
                snapshot: snapshot
            ),
            as: MLXImportCacheResponse.self
        )
        currentMetrics = response.metrics ?? currentMetrics
    }

    public func validateCacheCompatibility(_ manifest: CacheManifest) async throws {
        guard manifest.backend == .mlx else {
            throw CompatibilityIssue(reason: "Cache backend \(manifest.backend.rawValue) does not match MLX runtime.")
        }
        guard manifest.modelID == install.id else {
            throw CompatibilityIssue(reason: "Cache model \(manifest.modelID) does not match loaded model \(install.id).")
        }
    }

    public func unload() async {
        try? FileManager.default.removeItem(at: stateFileURL)
    }

    private func bridgePythonExecutableURL() -> URL {
        RuntimePathResolver.pythonExecutableURL(
            configuredPath: bridge.configuration.pythonExecutablePath,
            environment: ProcessInfo.processInfo.environment,
            executablePath: ExecutablePath.resolvedPath,
            sourceFilePath: #filePath
        )
    }

    private func bridgeHelperScriptURL() throws -> URL {
        try RuntimePathResolver.helperScriptURL(
            configuredPath: bridge.configuration.helperScriptPath,
            environment: ProcessInfo.processInfo.environment,
            executablePath: ExecutablePath.resolvedPath,
            sourceFilePath: #filePath
        )
    }
}

private struct MLXGenerateRequest: Codable, Sendable {
    var modelPath: String
    var modelID: String
    var tokenizerID: String?
    var session: ChatSession
    var config: GenerationConfig
    var stateFilePath: String
    var kvMode: CacheMode
    var sessionIntent: SessionIntent
    var triattentionCalibPath: String?
    var triattentionBudget: Int
}

private struct MLXGenerateResponse: Codable, Sendable {
    var text: String
    var metrics: Metrics
}

private struct MLXGenerateEvent: Codable, Sendable {
    var event: String
    var text: String?
    var metrics: Metrics?
}

private struct MLXPrepareRequest: Codable, Sendable {
    var modelPath: String
    var modelID: String
    var tokenizerID: String?
    var session: ChatSession
    var stateFilePath: String
    var kvMode: CacheMode
    var sessionIntent: SessionIntent
    var triattentionCalibPath: String?
    var triattentionBudget: Int
}

private struct MLXPrepareResponse: Codable, Sendable {
    var snapshot: CacheSnapshot
    var metrics: Metrics
}

private struct MLXExportCacheRequest: Codable, Sendable {
    var modelPath: String
    var modelID: String
    var stateFilePath: String
}

private struct MLXExportCacheResponse: Codable, Sendable {
    var snapshot: CacheSnapshot
    var metrics: Metrics?
}

private struct MLXImportCacheRequest: Codable, Sendable {
    var modelPath: String
    var modelID: String
    var stateFilePath: String
    var snapshot: CacheSnapshot
}

private struct MLXImportCacheResponse: Codable, Sendable {
    var importedLayerCount: Int
    var metrics: Metrics?
}


/// Thread-safe holder for the one-shot `mlx-generate` subprocess so a cancellation delivered on a different
/// executor than the reader task can terminate it exactly once. `terminate()` is idempotent and a no-op once
/// the process has already exited.
private final class MLXProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var terminated = false
    func set(_ p: Process) { lock.lock(); let dead = terminated; process = p; lock.unlock(); if dead { Self.kill(p) } }
    func terminate() {
        lock.lock(); let p = process; terminated = true; lock.unlock()
        if let p { Self.kill(p) }
    }
    /// SIGTERM, then escalate to SIGKILL if the worker is still alive after a short grace. A worker deep in a
    /// 17 GB mmap/Metal model load can leave SIGTERM queued for many seconds, so the escalation guarantees the
    /// subprocess (and its RAM) is released promptly on cancellation.
    private static func kill(_ p: Process) {
        guard p.isRunning else { return }
        p.terminate()                                   // SIGTERM
        let pid = p.processIdentifier
        Task.detached {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if p.isRunning { Foundation.kill(pid, SIGKILL) }
        }
    }
}
