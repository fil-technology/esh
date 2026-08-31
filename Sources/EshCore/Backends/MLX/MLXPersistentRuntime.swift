import Foundation

/// Generation request sent to the persistent `mlx-serve` worker. Mirrors the one-shot
/// `mlx-generate` request so both paths drive identical Python logic.
private struct MLXServeGenerateRequest: Encodable, Sendable {
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

/// A `BackendRuntime` backed by a persistent, weights-resident MLX worker process. The model is
/// loaded ONCE when the runtime is created (via `MLXBackend.loadRuntime`) and stays resident until
/// `unload()`. Generation requests are streamed to the already-loaded worker — no per-request model
/// reload — which is the whole point of true residency.
///
/// `RuntimeLifecycleManager` owns instances of this type; eviction/idle/pressure handling and bounded
/// concurrency live there, not here (no parallel runtime manager).
public final class MLXPersistentRuntime: BackendRuntime, ResidencyReporting, @unchecked Sendable {
    public let backend: BackendKind = .mlx
    public let modelID: String

    private let worker: MLXWorkerProcess
    private let install: ModelInstall
    private let stateFileURL: URL
    private let oneShot: MLXRuntime          // delegate for cache export/import (cold ops)
    private let lock = NSLock()
    private var currentMetrics: Metrics
    private let loadMilliseconds: Double
    private let residentMemoryBytes: Int64?

    init(
        worker: MLXWorkerProcess,
        bridge: MLXBridge,
        install: ModelInstall,
        readyInfo: MLXWorkerProcess.ReadyInfo,
        stateFileURL: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("esh-persistent-\(UUID().uuidString).json")
    ) {
        self.worker = worker
        self.install = install
        self.modelID = install.id
        self.stateFileURL = stateFileURL
        self.oneShot = MLXRuntime(bridge: bridge, install: install, stateFileURL: stateFileURL)
        self.loadMilliseconds = readyInfo.loadMilliseconds
        self.residentMemoryBytes = readyInfo.memoryBytes
        self.currentMetrics = Metrics(memoryBytes: readyInfo.memoryBytes)
    }

    /// True weights residency: the worker has the model loaded in memory for its whole lifetime.
    public var residency: RuntimeResidency { worker.isAlive ? .weightsResident : .handleCached }

    /// One-time model load latency (ms) measured by the worker at startup.
    public var loadLatencyMilliseconds: Double { loadMilliseconds }

    public var isHealthy: Bool { worker.isAlive }

    public var metrics: Metrics {
        lock.lock(); defer { lock.unlock() }
        return currentMetrics
    }

    private func updateMetrics(_ metrics: Metrics) {
        lock.lock(); currentMetrics = metrics; lock.unlock()
    }

    public func prepare(session: ChatSession) async throws {
        // No separate cache-build pass: the persistent worker builds/reuses the prompt cache inline on
        // the first generate (reading/writing the same state file), so a prewarm here would just be a
        // redundant model pass. Residency is already established at load time.
    }

    public func generate(
        session: ChatSession,
        config: GenerationConfig
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let requestJSON: Data
            do {
                let normalizedSession = PromptSessionNormalizer().normalized(session: session)
                let request = MLXServeGenerateRequest(
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
                // Compact (single-line) encoding — the worker protocol is newline-delimited.
                requestJSON = try JSONCoding.compactEncoder.encode(request)
            } catch {
                continuation.finish(throwing: error)
                return
            }

            let events = worker.generate(requestJSON: requestJSON)
            let task = Task {
                do {
                    for try await event in events {
                        switch event {
                        case let .token(text):
                            continuation.yield(text)
                        case let .done(metrics):
                            if let metrics {
                                self.updateMetrics(metrics)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { reason in
                if case .cancelled = reason { task.cancel() }
            }
        }
    }

    public func exportRuntimeCache() async throws -> CacheSnapshot {
        try await oneShot.exportRuntimeCache()
    }

    public func importRuntimeCache(_ snapshot: CacheSnapshot) async throws {
        try await oneShot.importRuntimeCache(snapshot)
    }

    public func validateCacheCompatibility(_ manifest: CacheManifest) async throws {
        try await oneShot.validateCacheCompatibility(manifest)
    }

    public func unload() async {
        worker.shutdown()
        try? FileManager.default.removeItem(at: stateFileURL)
    }
}
