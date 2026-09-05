import Foundation
import Testing
@testable import EshCore

// esh 2.1 — Voice 2.1 realtime transport integration: a real WebSocket client drives the real server over a
// loopback socket, with FAKE STT/LLM/TTS (fast, deterministic). Proves the duplex path end-to-end: handshake,
// mic PCM → server VAD → endpoint → STT → LLM → streamed TTS → binary audio frames, plus barge-in + disconnect.

private struct FakeTranscriber: VoiceTranscriber {
    let text: String
    func transcribe(_ a: VoiceAudioInput, language: String?, model: String?) async throws -> String { text }
}
private struct FakeResponder: VoiceResponder {
    let deltas: [String]
    func respond(context: [VoiceTurn], language: String?, model: String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { c in deltas.forEach { c.yield($0) }; c.finish() }
    }
}
private struct FastSpeaker: VoiceSpeaker {
    func speak(_ t: String, language: String?, model: String?) -> AsyncThrowingStream<VoiceAudioChunk, Error> {
        AsyncThrowingStream { c in c.yield(VoiceAudioChunk(bytes: Data([1,2,3,4]), sampleRate: 24000, isFinal: true)); c.finish() }
    }
}
private struct SlowSpeaker: VoiceSpeaker {
    func speak(_ t: String, language: String?, model: String?) -> AsyncThrowingStream<VoiceAudioChunk, Error> {
        AsyncThrowingStream { c in
            let task = Task {
                c.yield(VoiceAudioChunk(bytes: Data([9]), sampleRate: 24000))
                do { for _ in 0..<200 { try Task.checkCancellation(); try await Task.sleep(nanoseconds: 20_000_000); c.yield(VoiceAudioChunk(bytes: Data([9]), sampleRate: 24000)) }; c.finish() }
                catch { c.finish(throwing: error) }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
}

private func loudPCM(ms: Int, sr: Int = 16000) -> Data {
    let n = sr * ms / 1000; var d = Data(capacity: n * 2)
    let amp: Int16 = 8000
    for i in 0..<n { let v = (i % 2 == 0) ? amp : -amp; d.append(UInt8(truncatingIfNeeded: v)); d.append(UInt8(truncatingIfNeeded: v >> 8)) }
    return d
}
private func silencePCM(ms: Int, sr: Int = 16000) -> Data { Data(count: (sr * ms / 1000) * 2) }

private func withTimeout<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async -> T?) async -> T? {
    await withTaskGroup(of: T?.self) { g in
        g.addTask { await op() }
        g.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); return nil }
        let first = await g.next() ?? nil
        g.cancelAll()
        return first
    }
}

private func startServer(_ speaker: @escaping @Sendable () -> VoiceSpeaker,
                         deltas: [String] = ["Hi there. "]) async throws -> (VoiceWebSocketServer, UInt16) {
    let srv = try VoiceWebSocketServer(port: 0) { cfg in
        VoiceSessionOrchestrator(config: cfg, transcriber: FakeTranscriber(text: "hello there"),
                                 responder: FakeResponder(deltas: deltas), speaker: speaker())
    }
    let port = try await srv.startAndWait()
    FileHandle.standardError.write(Data("RESOLVED_PORT=\(port)\n".utf8))
    return (srv, port)
}

@Suite(.serialized)
struct VoiceTransportTests {

    @Test
    func fullTurnOverWebSocket() async throws {
        let (srv, port) = try await startServer({ FastSpeaker() })
        defer { srv.stop() }
        try? await Task.sleep(nanoseconds: 150_000_000)
        let client = VoiceWebSocketClient(port: port)
        try await client.connect()
        client.sendControl(VoiceControl(t: "start", sampleRate: 16000))
        // ~400 ms speech then ~1600 ms silence → VAD endpoints the utterance.
        let sim = VoiceRealtimeSimulator(port: port)
        _ = sim
        client.sendAudioPCM(loudPCM(ms: 400))
        client.sendAudioPCM(silencePCM(ms: 1600))

        let result = await withTimeout(8) { () -> (Bool, Bool, Bool)? in
            var sawTranscript = false, sawFinalText = false, sawAudio = false
            for await m in client.messages {
                switch m {
                case .event(let e):
                    if e.t == "transcript.final" { sawTranscript = true }
                    if e.t == "assistant.text_final" { sawFinalText = true }
                    if e.t == "tts.finished" { return (sawTranscript, sawFinalText, sawAudio) }
                case .audio: sawAudio = true
                case .closed: return (sawTranscript, sawFinalText, sawAudio)
                }
            }
            return (sawTranscript, sawFinalText, sawAudio)
        }
        client.close()
        #expect(result != nil)
        #expect(result?.0 == true, "expected transcript.final")
        #expect(result?.1 == true, "expected assistant.text_final")
        #expect(result?.2 == true, "expected at least one binary TTS audio frame")
    }

    @Test
    func bargeInOverWebSocket() async throws {
        let (srv, port) = try await startServer({ SlowSpeaker() }, deltas: ["Let me explain this at length. "])
        defer { srv.stop() }
        try? await Task.sleep(nanoseconds: 150_000_000)
        let client = VoiceWebSocketClient(port: port)
        try await client.connect()
        client.sendControl(VoiceControl(t: "start", sampleRate: 16000))
        client.sendAudioPCM(loudPCM(ms: 400))
        client.sendAudioPCM(silencePCM(ms: 1600))

        let interrupted = await withTimeout(10) { () -> Bool? in
            var startedSpeaking = false
            for await m in client.messages {
                if case .audio = m, !startedSpeaking {
                    startedSpeaking = true
                    // User barges in mid-playback: stream new speech.
                    client.sendAudioPCM(loudPCM(ms: 400))
                    client.sendAudioPCM(silencePCM(ms: 1600))
                }
                if case .event(let e) = m, e.t == "playback.cancelled" { return true }
                if case .closed = m { return false }
            }
            return false
        }
        client.close()
        #expect(interrupted == true, "expected playback.cancelled after barge-in over the transport")
    }

    @Test
    func disconnectMidTurnLeavesServerHealthy() async throws {
        let (srv, port) = try await startServer({ SlowSpeaker() })
        defer { srv.stop() }
        try? await Task.sleep(nanoseconds: 150_000_000)
        // Turn 1: connect, start a turn, then hard-disconnect mid-playback.
        let c1 = VoiceWebSocketClient(port: port)
        try await c1.connect()
        c1.sendControl(VoiceControl(t: "start", sampleRate: 16000))
        c1.sendAudioPCM(loudPCM(ms: 400)); c1.sendAudioPCM(silencePCM(ms: 1600))
        _ = await withTimeout(6) { () -> Bool? in
            for await m in c1.messages { if case .audio = m { return true } }
            return false
        }
        c1.close()   // disconnect mid-turn
        try? await Task.sleep(nanoseconds: 200_000_000)
        // Turn 2: a NEW connection must still work → server stayed healthy, no zombie.
        let c2 = VoiceWebSocketClient(port: port)
        try await c2.connect()
        c2.sendControl(VoiceControl(t: "start", sampleRate: 16000))
        c2.sendAudioPCM(loudPCM(ms: 400)); c2.sendAudioPCM(silencePCM(ms: 1600))
        let ok = await withTimeout(8) { () -> Bool? in
            for await m in c2.messages { if case .event(let e) = m, e.t == "transcript.final" { return true } }
            return false
        }
        c2.close()
        #expect(ok == true, "a new session after a mid-turn disconnect must still complete")
    }
}
