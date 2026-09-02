import Foundation

/// Owns a persistent STT worker (M12) so the speech-to-text model stays resident across requests
/// instead of reloading Python + weights every call (~4–6 s → warm). Lazily starts a worker for the
/// requested model, reuses it, switches models on demand, recovers from a crashed worker, and evicts
/// after an idle period so speech doesn't hold unified memory forever while a large LLM is resident.
///
/// This is the STT half of the M12 speech runtime; TTS residency is handled separately (TTSMLX caches
/// weights). A future `SpeechBackend`-style abstraction (M21) can unify both under the warm pool.
public actor SpeechRuntimeManager {
    private let bridge: MLXBridge
    private let idleTimeout: TimeInterval
    private var worker: SpeechWorkerProcess?
    private var workerModel: String?
    private var idleTask: Task<Void, Never>?

    public init(bridge: MLXBridge = .init(), idleTimeout: TimeInterval = 300) {
        self.bridge = bridge
        self.idleTimeout = idleTimeout
    }

    /// Transcribe on the resident worker, starting/switching it as needed. Retries once if the worker
    /// died (crash recovery).
    public func transcribe(audioPath: String, model: String?, language: String?) async throws -> String {
        let modelPath = model ?? SpeechToTextService.defaultModel
        let active = try await ensureWorker(modelPath: modelPath)
        do {
            let text = try await active.transcribe(audioPath: audioPath, language: language)
            scheduleIdleEviction()
            return text
        } catch is SpeechWorkerError {
            // Worker crashed mid-request: drop it and retry once on a fresh worker.
            if worker === active { dropWorker() }
            let restarted = try await ensureWorker(modelPath: modelPath)
            let text = try await restarted.transcribe(audioPath: audioPath, language: language)
            scheduleIdleEviction()
            return text
        }
    }

    /// The currently-resident STT model, or nil if none is warm (for honest residency reporting).
    public func residentModel() -> String? {
        (worker?.isAlive == true) ? workerModel : nil
    }

    public func shutdown() {
        idleTask?.cancel(); idleTask = nil
        worker?.shutdown()
        dropWorker()
    }

    // MARK: - Internals

    private func ensureWorker(modelPath: String) async throws -> SpeechWorkerProcess {
        if let worker, worker.isAlive, workerModel == modelPath { return worker }
        // Different model or dead worker → replace.
        worker?.shutdown()
        dropWorker()
        let python = try bridge.resolvedPythonExecutable()
        let script = try bridge.resolvedHelperScript()
        let fresh = SpeechWorkerProcess(modelPath: modelPath)
        try await fresh.start(pythonURL: python, bridgeScriptURL: script, modelID: modelPath)
        worker = fresh
        workerModel = modelPath
        return fresh
    }

    private func dropWorker() { worker = nil; workerModel = nil }

    private func scheduleIdleEviction() {
        idleTask?.cancel()
        guard idleTimeout > 0 else { return }
        idleTask = Task { [idleTimeout] in
            try? await Task.sleep(nanoseconds: UInt64(idleTimeout) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self.evictIfIdle()
        }
    }

    private func evictIfIdle() {
        worker?.shutdown()
        dropWorker()
    }
}
