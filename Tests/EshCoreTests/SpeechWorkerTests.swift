import Foundation
import Testing
@testable import EshCore

@Suite
struct SpeechWorkerTests {
    private func decode(_ json: String) throws -> SpeechWorkerLine {
        try JSONCoding.decoder.decode(SpeechWorkerLine.self, from: Data(json.utf8))
    }

    // M12: the persistent STT worker's stdio protocol must decode ready/result/error lines.
    @Test
    func decodesReadyEvent() throws {
        let line = try decode(#"{"event":"ready","loadMs":1234.5,"memoryBytes":987654321,"model":"parakeet"}"#)
        #expect(line.event == "ready")
        #expect(line.loadMs == 1234.5)
        #expect(line.memoryBytes == 987654321)
        #expect(line.id == nil)
    }

    @Test
    func decodesResultEvent() throws {
        let line = try decode(#"{"id":"abc","event":"result","text":"hello world","ms":42.0}"#)
        #expect(line.id == "abc")
        #expect(line.event == "result")
        #expect(line.text == "hello world")
        #expect(line.ms == 42.0)
    }

    @Test
    func decodesErrorEvent() throws {
        let line = try decode(#"{"id":"abc","event":"error","message":"boom"}"#)
        #expect(line.event == "error")
        #expect(line.message == "boom")
    }

    // A fresh manager reports no resident model until a transcription warms one.
    @Test
    func managerHasNoResidentModelBeforeUse() async {
        let manager = SpeechRuntimeManager(idleTimeout: 0)
        let resident = await manager.residentModel()
        #expect(resident == nil)
    }

    // M12 follow-up (on-device, opt-in). Proves the real gate end-to-end: a live STT worker publishes
    // its footprint as the shared pool's reservation, and an LLM that can't otherwise fit reclaims the
    // speech worker and loads. Skipped unless ESH_SPEECH_IT_WAV points at a real audio file (so CI and
    // machines without the Python/MLX stack skip it). Run: ESH_SPEECH_IT_WAV=/path/hello.wav swift test.
    @Test
    func speechWorkerReservesBudgetAndIsReclaimedUnderLLMPressure() async throws {
        guard let wav = ProcessInfo.processInfo.environment["ESH_SPEECH_IT_WAV"],
              FileManager.default.fileExists(atPath: wav) else { return }
        // Budget sized so ANY positive speech reservation forces the LLM to reclaim: big LLM estimate
        // 1.8 GB, budget 1.85 GB → 1.8 + reservation(≥0.1) > 1.85 until speech is dropped.
        let pool = RuntimeLifecycleManager(
            config: .init(memorySafetyReserveGB: 0), usableBudgetGB: 1.85,
            estimator: { Double($0.sizeBytes) / 1_073_741_824 },
            loader: { ITMockRuntime(modelID: $0.id) })
        let speech = SpeechRuntimeManager(idleTimeout: 0, lifecycleManager: pool)

        _ = try await speech.transcribe(audioPath: wav, model: nil, language: nil)   // loads the worker
        let afterLoad = await pool.status()
        #expect(afterLoad.speechReservationGB > 0)                 // reservation published (measured ~2.3 GB for parakeet)
        #expect(await speech.residentModel() != nil)               // worker resident

        let big = ModelInstall(
            id: "big-llm",
            spec: ModelSpec(id: "big-llm", displayName: "big", backend: .mlx,
                            source: ModelSource(kind: .localPath, reference: "local/big")),
            installPath: "/tmp/big", sizeBytes: Int64(1.8 * 1_073_741_824), backendFormat: "mlx")
        let runtime = try await pool.acquire(install: big)          // must reclaim speech to fit
        #expect(runtime.modelID == "big-llm")
        let afterLLM = await pool.status()
        #expect(afterLLM.speechReservationGB == 0)                 // speech reclaimed
        #expect(await speech.residentModel() == nil)               // worker dropped
        await pool.release(modelID: "big-llm")
        await speech.shutdown()
    }
}

// Minimal BackendRuntime stub for the opt-in speech/pool integration test.
private final class ITMockRuntime: BackendRuntime, @unchecked Sendable {
    let backend: BackendKind = .mlx
    let modelID: String
    var metrics: Metrics { get async { Metrics(memoryBytes: 1_000) } }
    init(modelID: String) { self.modelID = modelID }
    func prepare(session: ChatSession) async throws {}
    func generate(session: ChatSession, config: GenerationConfig) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func exportRuntimeCache() async throws -> CacheSnapshot { throw StoreError.invalidManifest("n/a") }
    func importRuntimeCache(_ snapshot: CacheSnapshot) async throws {}
    func validateCacheCompatibility(_ manifest: CacheManifest) async throws {}
    func unload() async {}
}
