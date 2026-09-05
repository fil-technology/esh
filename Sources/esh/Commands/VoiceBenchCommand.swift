import Foundation
import EshCore

// esh 2.1 — Voice 2.1 WARM co-residency benchmark (spec §2/§3). The cold WAV-driven turn (~38 s) was
// architecture proof, not realtime UX. This runs N turns through ONE VoiceSessionOrchestrator with SHARED,
// resident collaborators (warm STT worker, warm LLM via the lifecycle pool, reused TTS synthesizer) and
// reports the per-turn §14 latency breakdown so cold (turn 1) vs warm (turns 2+) is measured on real hardware.
//
// Usage: esh voice-bench --in <utterance.wav> [--turns N] [--model <llm>] [--tts <model>]
// Tip: run with ESH_MLX_PERSISTENT=1 so the MLX LLM stays weights-resident across turns.
enum VoiceBenchCommand {
    static func run(arguments: [String], currentDirectoryURL: URL) async throws {
        guard let inPath = CommandSupport.optionalValue(flag: "--in", in: arguments) else {
            throw StoreError.invalidManifest("voice-bench requires --in <utterance.wav>")
        }
        let audio = try Data(contentsOf: URL(fileURLWithPath: inPath, relativeTo: currentDirectoryURL))
        let turns = max(1, Int(CommandSupport.optionalValue(flag: "--turns", in: arguments) ?? "3") ?? 3)
        let root = PersistenceRoot.default()
        let config = try? EshConfigStore().load()
        let modelStore = FileModelStore(root: root)
        let installs = try modelStore.listInstalls()
        let pinnedLLM = CommandSupport.optionalValue(flag: "--model", in: arguments)
        guard let llm = pinnedLLM ?? installs.first(where: { $0.spec.backend == .mlx })?.id ?? installs.first?.id else {
            throw StoreError.notFound("No installed language model.")
        }
        let ttsModel = CommandSupport.optionalValue(flag: "--tts", in: arguments) ?? config?.defaults.ttsModel

        // Shared, resident collaborators — the whole point of the benchmark.
        let pool = OpenAICompatibleService.makeLifecycleManager()
        let inference = ExternalInferenceService(
            modelStore: modelStore, sessionStore: FileSessionStore(root: root),
            cacheStore: FileCacheStore(root: root), lifecycleManager: pool)
        let transcriber = SpeechRuntimeTranscriber(lifecycleManager: pool)
        let responder = LanguageResponder(inference: inference, resolveModel: { _ in llm })
        let speaker = BufferedTTSSpeaker(lifecycleManager: pool)
        let orch = VoiceSessionOrchestrator(
            config: VoiceSessionConfig(inferenceModel: llm, ttsModel: ttsModel),
            transcriber: transcriber, responder: responder, speaker: speaker)

        func e(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
        e("voice-bench: llm=\(llm) tts=\(ttsModel ?? "default") turns=\(turns) persistentMLX=\(ProcessInfo.processInfo.environment["ESH_MLX_PERSISTENT"] == "1")")

        // Drain events so the stream never backpressures; we read metrics via lastTurnMetrics().
        let drain = Task { for await _ in orch.events {} }
        await orch.start()

        func pad(_ s: String, _ w: Int) -> String { s.count >= w ? s : String(repeating: " ", count: w - s.count) + s }
        func ms(_ a: Double?, _ b: Double?) -> String {
            guard let a, let b, b >= a else { return "n/a" }
            return String(format: "%.0fms", (b - a) * 1000)
        }
        e([pad("turn",4), pad("STT",9), pad("LLMtok",9), pad("TTSaud",9), pad("→audible",10), pad("freeMB",8)].joined(separator: " "))
        var warmAudible: [Double] = []
        for i in 1...turns {
            await orch.inputSpeechStarted()
            await orch.submitUtterance(VoiceAudioInput(bytes: audio, format: "wav"))
            await orch.awaitTurn()
            let m = await orch.lastTurnMetrics()
            let free = SystemMemory.snapshot().map { Int($0.availableBytes / 1_048_576) } ?? -1
            if i > 1, let audible = m.speechEndToAudibleMs { warmAudible.append(audible) }
            e([pad(String(i),4),
               pad(ms(m.speechEndedAt, m.finalTranscriptAt),9),
               pad(ms(m.finalTranscriptAt, m.firstTokenAt),9),
               pad(ms(m.firstTokenAt, m.firstAudibleAt),9),
               pad(ms(m.speechEndedAt, m.firstAudibleAt),10),
               pad(String(free),8)].joined(separator: " "))
        }
        await orch.end()
        drain.cancel()
        if !warmAudible.isEmpty {
            let avg = warmAudible.reduce(0, +) / Double(warmAudible.count)
            e(String(format: "warm endpoint→audible avg: %.0f ms (n=%d)", avg, warmAudible.count))
        }
        print("voice-bench: OK")
    }
}
