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
    // M12 follow-up: when set, the STT worker shares the LLM warm pool's memory budget. While a worker
    // is resident we publish its live footprint as the pool's external reservation (so an LLM won't
    // over-allocate on top of it), and the pool can call our reclaim to drop the worker under pressure.
    private let lifecycleManager: RuntimeLifecycleManager?
    private static let fallbackReserveGB = 1.0   // STT models are small; used only if the worker didn't report bytes

    public init(bridge: MLXBridge = .init(), idleTimeout: TimeInterval = 300,
                lifecycleManager: RuntimeLifecycleManager? = nil) {
        self.bridge = bridge
        self.idleTimeout = idleTimeout
        self.lifecycleManager = lifecycleManager
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
        let pool = lifecycleManager
        Task { await pool?.setExternalReservation(gigabytes: 0, reclaim: nil) }
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
        await publishReservation(bytes: fresh.memoryBytes)
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

    private func evictIfIdle() async {
        worker?.shutdown()
        dropWorker()
        await clearReservation()
    }

    // MARK: - Warm-pool memory reservation (M12 follow-up)

    /// Publish the resident worker's footprint to the shared pool so an LLM reserves it out of the
    /// budget, and register a reclaim the pool can call to drop us under memory pressure.
    private func publishReservation(bytes: Int64?) async {
        guard let pool = lifecycleManager else { return }
        let gb = bytes.map { max(0.1, Double($0) / 1_073_741_824) } ?? Self.fallbackReserveGB
        await pool.setExternalReservation(gigabytes: gb, reclaim: { [weak self] in
            await self?.reclaimForMemoryPressure()
        })
    }

    private func clearReservation() async {
        await lifecycleManager?.setExternalReservation(gigabytes: 0, reclaim: nil)
    }

    /// Invoked by the warm pool when an LLM otherwise can't fit: drop the STT worker and free the
    /// reservation. The next transcription lazily starts a fresh worker.
    private func reclaimForMemoryPressure() async {
        idleTask?.cancel(); idleTask = nil
        worker?.shutdown()
        dropWorker()
        await clearReservation()
    }
}
