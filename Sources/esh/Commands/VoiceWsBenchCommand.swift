import Foundation
import EshCore

// esh 2.1 — Voice 2.1 SHIPPING-PATH latency benchmark (spec Gate 2). Unlike voice-bench (which drives the
// VoiceSessionOrchestrator in-process), this exercises the ACTUAL production transport end-to-end:
//
//   client PCM → WebSocket → server VAD → STT → Voice/LLM → TTS → WebSocket binary audio → client (playable)
//
// The server runs REAL adapters (SpeechRuntimeTranscriber / LanguageResponder / BufferedTTSSpeaker) exactly as
// `esh serve` wires them. Latency is measured from server-side events observed on the client: the endpoint is
// `vad.speech_ended`, "playable" is the first binary VoiceAudioFrame. Cold = turn 1, warm = turns 2+.
//
// Usage: esh voice-ws-bench --in <utterance16k.wav> [--turns N] [--model <llm>] [--tts <model>]
// Tip: ESH_MLX_PERSISTENT=1 keeps the MLX LLM weights-resident across turns (true warm numbers).
enum VoiceWsBenchCommand {
    static func run(arguments: [String], currentDirectoryURL: URL) async throws {
        guard let inPath = CommandSupport.optionalValue(flag: "--in", in: arguments) else {
            throw StoreError.invalidManifest("voice-ws-bench requires --in <utterance16k.wav> (16 kHz mono PCM16)")
        }
        let turns = max(1, Int(CommandSupport.optionalValue(flag: "--turns", in: arguments) ?? "4") ?? 4)
        let wav = try Data(contentsOf: URL(fileURLWithPath: inPath, relativeTo: currentDirectoryURL))
        let (pcm, sr) = try Self.pcm16FromWav(wav)

        let root = PersistenceRoot.default()
        let config = try? EshConfigStore().load()
        let modelStore = FileModelStore(root: root)
        let installs = try modelStore.listInstalls()
        let pinnedLLM = CommandSupport.optionalValue(flag: "--model", in: arguments)
        guard let llm = pinnedLLM ?? installs.first(where: { $0.spec.backend == .mlx })?.id ?? installs.first?.id else {
            throw StoreError.notFound("No installed language model.")
        }
        let ttsModel = CommandSupport.optionalValue(flag: "--tts", in: arguments) ?? config?.defaults.ttsModel

        // Shared, resident collaborators — identical to `esh serve` (real STT/LLM/TTS).
        let pool = OpenAICompatibleService.makeLifecycleManager()
        let inference = ExternalInferenceService(
            modelStore: modelStore, sessionStore: FileSessionStore(root: root),
            cacheStore: FileCacheStore(root: root), lifecycleManager: pool)

        func e(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
        e("voice-ws-bench: llm=\(llm) tts=\(ttsModel ?? "default") turns=\(turns) sr=\(sr) pcmBytes=\(pcm.count) persistentMLX=\(ProcessInfo.processInfo.environment["ESH_MLX_PERSISTENT"] == "1")")

        let server = try VoiceWebSocketServer(port: 0) { cfg in
            VoiceSessionOrchestrator(
                config: cfg,
                transcriber: SpeechRuntimeTranscriber(lifecycleManager: pool),
                responder: LanguageResponder(inference: inference, resolveModel: { pin in pin ?? cfg.inferenceModel ?? llm }),
                speaker: BufferedTTSSpeaker(lifecycleManager: pool))
        }
        let port = try await server.startAndWait()
        defer { server.stop() }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let client = VoiceWebSocketClient(port: port)
        try await client.connect()
        client.sendControl(VoiceControl(t: "start", inferenceModel: llm, ttsModel: ttsModel, sampleRate: sr))

        func pad(_ s: String, _ w: Int) -> String { s.count >= w ? s : String(repeating: " ", count: w - s.count) + s }
        func ms(_ a: Double?, _ b: Double?) -> String { guard let a, let b, b >= a else { return "n/a" }; return String(format: "%.0fms", (b - a) * 1000) }
        e([pad("turn",4), pad("STT",9), pad("TTFT",9), pad("TTSaud",9), pad("→playable",11), pad("freeMB",8)].joined(separator: " "))

        var warm: [Double] = []
        var msgIter = client.messages.makeAsyncIterator()

        for i in 1...turns {
            // Endpoint the utterance: real speech PCM, then trailing silence LONGER than the VAD's
            // trailingSilenceMs (default 1400 ms) so the server declares the endpoint. The server re-chunks
            // incoming PCM into fixed VAD frames itself, so the blob send is fine.
            client.sendAudioPCM(pcm)
            client.sendAudioPCM(Data(count: (sr / 1000) * 1600 * 2))

            var vadEnded: Double?, transcript: Double?, firstTok: Double?, playable: Double?
            loop: while true {
                guard let m = await msgIter.next() else { break }
                switch m {
                case .event(let env):
                    let now = Date().timeIntervalSince1970
                    switch env.t {
                    case "vad.speech_ended": if vadEnded == nil { vadEnded = now }
                    case "transcript.final": if transcript == nil { transcript = now }
                    case "assistant.text_delta": if firstTok == nil { firstTok = now }
                    case "tts.finished": break loop
                    case "session.state":
                        // After the endpoint fired, a return to listening means the turn concluded (incl. the
                        // empty-transcript case where STT heard nothing) — don't wait for tts.finished forever.
                        if env.state == "listening", vadEnded != nil { break loop }
                    default: break
                    }
                case .audio:
                    if playable == nil { playable = Date().timeIntervalSince1970 }
                case .closed:
                    break loop
                }
            }
            let free = SystemMemory.snapshot().map { Int($0.availableBytes / 1_048_576) } ?? -1
            if i > 1, let v = vadEnded, let p = playable { warm.append((p - v) * 1000) }
            e([pad(String(i),4),
               pad(ms(vadEnded, transcript),9),
               pad(ms(transcript, firstTok),9),
               pad(ms(firstTok, playable),9),
               pad(ms(vadEnded, playable),11),
               pad(String(free),8)].joined(separator: " "))
        }
        client.close()
        if !warm.isEmpty {
            let avg = warm.reduce(0,+) / Double(warm.count)
            e(String(format: "warm endpoint→playable avg: %.0f ms (n=%d)  [target <2500, stretch <1500]", avg, warm.count))
        }
        print("voice-ws-bench: OK")
    }

    /// Extract PCM16 samples + sample rate from a canonical WAV (parses fmt/data chunks; not header-position dependent).
    static func pcm16FromWav(_ data: Data) throws -> (Data, Int) {
        guard data.count > 44, data.prefix(4) == Data("RIFF".utf8), data.subdata(in: 8..<12) == Data("WAVE".utf8) else {
            throw StoreError.invalidManifest("voice-ws-bench: --in must be a WAV file")
        }
        func u32(_ o: Int) -> Int { Int(data[o]) | Int(data[o+1])<<8 | Int(data[o+2])<<16 | Int(data[o+3])<<24 }
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o+1])<<8 }
        var o = 12, sr = 16000
        var pcm = Data()
        while o + 8 <= data.count {
            let id = data.subdata(in: o..<o+4); let sz = u32(o+4); let body = o + 8
            if id == Data("fmt ".utf8) { sr = u32(body + 4) }
            else if id == Data("data".utf8) {
                let end = min(body + sz, data.count); pcm = data.subdata(in: body..<end)
            }
            o = body + sz + (sz & 1)
        }
        guard !pcm.isEmpty else { throw StoreError.invalidManifest("voice-ws-bench: no data chunk in WAV") }
        return (pcm, sr)
    }
}
