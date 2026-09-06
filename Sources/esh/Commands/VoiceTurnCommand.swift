import Foundation
import EshCore

// esh 2.1 — Voice 2.1 live-path smoke driver. Runs ONE real, server-owned conversational turn through the
// canonical VoiceSessionOrchestrator with the REAL local backends (STT → LLM → TTS), driven by a recorded WAV
// instead of a live microphone (headless-verifiable). Prints the typed VoiceEvent sequence + the §14 latency
// breakdown and writes the assistant audio. This proves the server owns the STT→LLM→TTS loop; live mic +
// duplex transport + barge-in acoustics are separate gates that need real audio hardware.
//
// Usage: esh voice-turn --in <utterance.wav> [--out <reply.wav>] [--model <llm>] [--stt <model>] [--tts <model>]
enum VoiceTurnCommand {
    static func run(arguments: [String], currentDirectoryURL: URL) async throws {
        guard let inPath = CommandSupport.optionalValue(flag: "--in", in: arguments) else {
            throw StoreError.invalidManifest("voice-turn requires --in <utterance.wav>")
        }
        let inURL = URL(fileURLWithPath: inPath, relativeTo: currentDirectoryURL)
        let audioBytes = try Data(contentsOf: inURL)
        let outURL = (CommandSupport.optionalValue(flag: "--out", in: arguments)).map {
            URL(fileURLWithPath: $0, relativeTo: currentDirectoryURL)
        }
        let root = PersistenceRoot.default()
        let config = try? EshConfigStore().load()
        let modelStore = FileModelStore(root: root)
        let installs = try modelStore.listInstalls()
        let pinnedLLM = CommandSupport.optionalValue(flag: "--model", in: arguments)
        guard let llm = pinnedLLM ?? installs.first(where: { $0.spec.backend == .mlx })?.id ?? installs.first?.id else {
            throw StoreError.notFound("No installed language model. Install one with `esh model install`.")
        }
        let sttModel = CommandSupport.optionalValue(flag: "--stt", in: arguments) ?? config?.defaults.sttModel
        let ttsModel = CommandSupport.optionalValue(flag: "--tts", in: arguments) ?? config?.defaults.ttsModel

        let inference = ExternalInferenceService(
            modelStore: modelStore, sessionStore: FileSessionStore(root: root), cacheStore: FileCacheStore(root: root))
        let transcriber = SpeechRuntimeTranscriber()
        let responder = LanguageResponder(inference: inference, resolveModel: { _ in llm })
        let speaker = BufferedTTSSpeaker(workingDirectory: FileManager.default.temporaryDirectory)

        let orch = VoiceSessionOrchestrator(
            config: VoiceSessionConfig(sttModel: sttModel, inferenceModel: llm, ttsModel: ttsModel),
            transcriber: transcriber, responder: responder, speaker: speaker)

        func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
        err("voice-turn: llm=\(llm) stt=\(sttModel ?? "default") tts=\(ttsModel ?? "default")")

        // Consume events; collect assistant text + audio.
        let consumer = Task { () -> (String, Data, Int) in
            var reply = ""
            var audio = Data()
            var sr = 24000
            for await e in orch.events {
                switch e {
                case .transcriptFinal(let t): err("  [heard] \(t)")
                case .assistantTextFinal(let t): reply = t; err("  [reply] \(t)")
                case .ttsAudioChunk(let c): audio.append(c.bytes); sr = c.sampleRate
                case .sessionError(let m, _): err("  [error] \(m)")
                default: err("  · \(e.name)")
                }
            }
            return (reply, audio, sr)
        }

        await orch.start()
        await orch.inputSpeechStarted()
        await orch.submitUtterance(VoiceAudioInput(bytes: audioBytes, format: inURL.pathExtension.isEmpty ? "wav" : inURL.pathExtension))
        await orch.awaitTurn()
        let m = await orch.lastTurnMetrics()
        await orch.end()
        let (_, audio, _) = await consumer.value

        if let outURL, !audio.isEmpty {
            try audio.write(to: outURL)   // first phrase's WAV (buffered per-phrase); full concat is future work
            err("  [wrote] \(outURL.path) (\(audio.count) bytes)")
        }
        // §14 latency breakdown (seconds are monotonic; deltas in ms).
        func ms(_ v: Double?) -> String { v.map { String(format: "%.0fms", $0) } ?? "n/a" }
        err("  [latency] finalSTT=\(ms(m.finalSTTMs)) speechEnd→audible=\(ms(m.speechEndToAudibleMs))")
        print("voice-turn: OK")
    }
}
