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

/// STT that blocks long enough to disconnect "during STT". Honors cancellation so no worker is orphaned.
private struct SlowTranscriber: VoiceTranscriber {
    let text: String
    let delayMs: Int
    func transcribe(_ a: VoiceAudioInput, language: String?, model: String?) async throws -> String {
        try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
        try Task.checkCancellation()
        return text
    }
}
/// LLM whose stream stalls between the first and later deltas so we can disconnect "during LLM".
private struct SlowResponder: VoiceResponder {
    let deltas: [String]
    let gapMs: Int
    func respond(context: [VoiceTurn], language: String?, model: String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { c in
            let task = Task {
                do {
                    for (i, d) in deltas.enumerated() {
                        if i > 0 { try await Task.sleep(nanoseconds: UInt64(gapMs) * 1_000_000) }
                        try Task.checkCancellation()
                        c.yield(d)
                    }
                    c.finish()
                } catch { c.finish(throwing: error) }
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

/// Flexible server for the disconnect/cancellation matrix: inject any transcriber/responder/speaker so we can
/// stall a specific turn phase (STT/LLM/TTS) and then hard-disconnect or interrupt inside it.
private func startServerCustom(transcriber: @escaping @Sendable () -> VoiceTranscriber,
                               responder: @escaping @Sendable () -> VoiceResponder,
                               speaker: @escaping @Sendable () -> VoiceSpeaker) async throws -> (VoiceWebSocketServer, UInt16) {
    let srv = try VoiceWebSocketServer(port: 0) { cfg in
        VoiceSessionOrchestrator(config: cfg, transcriber: transcriber(), responder: responder(), speaker: speaker())
    }
    let port = try await srv.startAndWait()
    return (srv, port)
}

/// A fresh connection completes one full turn — the canonical "server is still healthy" probe.
private func newSessionCompletes(port: UInt16, timeout: Double = 8) async -> Bool {
    let client = VoiceWebSocketClient(port: port)
    do { try await client.connect() } catch { return false }
    client.sendControl(VoiceControl(t: "start", sampleRate: 16000))
    client.sendAudioPCM(loudPCM(ms: 400)); client.sendAudioPCM(silencePCM(ms: 1600))
    let ok = await withTimeout(timeout) { () -> Bool? in
        for await m in client.messages { if case .event(let e) = m, e.t == "transcript.final" { return true } }
        return false
    }
    client.close()
    return ok == true
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
    func enduranceTwentyTurnsOverWebSocket() async throws {
        let (srv, port) = try await startServer({ FastSpeaker() })
        defer { srv.stop() }
        let client = VoiceWebSocketClient(port: port)
        try await client.connect()
        client.sendControl(VoiceControl(t: "start", sampleRate: 16000))
        // Pace turns: send the next utterance only after the previous turn finishes (tts.finished → listening).
        let utter = loudPCM(ms: 400) + silencePCM(ms: 1600)
        let completed = await withTimeout(30) { () -> Int? in
            var done = 0, transcripts = 0
            client.sendAudioPCM(utter)
            for await m in client.messages {
                if case .event(let e) = m {
                    if e.t == "transcript.final" { transcripts += 1 }
                    if e.t == "session.error" { return -1 }
                    if e.t == "tts.finished" { done += 1; if done >= 20 { return transcripts }; client.sendAudioPCM(utter) }
                }
                if case .closed = m { return transcripts }
            }
            return transcripts
        }
        client.close()
        #expect(completed == 20, "expected 20 completed turns over one persistent connection, got \(completed ?? -99)")
    }

    @Test
    func malformedFramesAndUnknownControlKeepServerHealthy() async throws {
        let (srv, port) = try await startServer({ FastSpeaker() })
        defer { srv.stop() }
        let client = VoiceWebSocketClient(port: port)
        try await client.connect()
        client.sendControl(VoiceControl(t: "start", sampleRate: 16000))
        // Garbage the server must tolerate without dying: non-JSON text, unknown control op, stray tiny binary.
        client.sendControlRaw(Data("not json at all {{{".utf8))
        client.sendControl(VoiceControl(t: "bogus-op-should-be-ignored"))
        client.sendAudioPCM(Data([0x00]))   // 1 byte, sub-frame — must not crash the VAD accumulator
        // A valid turn must still work afterwards → server stayed healthy.
        client.sendAudioPCM(loudPCM(ms: 400)); client.sendAudioPCM(silencePCM(ms: 1600))
        let ok = await withTimeout(8) { () -> Bool? in
            for await m in client.messages { if case .event(let e) = m, e.t == "transcript.final" { return true } }
            return false
        }
        client.close()
        #expect(ok == true, "server must tolerate malformed/unknown input and still complete a valid turn")
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

    // MARK: - Disconnect / cancellation matrix (spec §6)

    @Test
    func disconnectDuringListeningLeavesServerHealthy() async throws {
        let (srv, port) = try await startServer({ FastSpeaker() })
        defer { srv.stop() }
        let c1 = VoiceWebSocketClient(port: port)
        try await c1.connect()
        c1.sendControl(VoiceControl(t: "start", sampleRate: 16000))
        // Never speak — disconnect while the session is idle in listening.
        c1.close()
        try? await Task.sleep(nanoseconds: 200_000_000)
        let ok = await newSessionCompletes(port: port)
        #expect(ok, "a new session after a disconnect during listening must complete")
    }

    @Test
    func disconnectDuringSTTLeavesServerHealthy() async throws {
        let (srv, port) = try await startServerCustom(
            transcriber: { SlowTranscriber(text: "hello there", delayMs: 1500) },
            responder: { FakeResponder(deltas: ["Hi. "]) }, speaker: { FastSpeaker() })
        defer { srv.stop() }
        let c1 = VoiceWebSocketClient(port: port)
        try await c1.connect()
        c1.sendControl(VoiceControl(t: "start", sampleRate: 16000))
        c1.sendAudioPCM(loudPCM(ms: 400)); c1.sendAudioPCM(silencePCM(ms: 1600))
        // Disconnect while STT is still running (before transcript.final).
        _ = await withTimeout(2) { () -> Bool? in
            for await m in c1.messages { if case .event(let e) = m, e.t == "vad.speech_ended" { return true } }
            return false
        }
        c1.close()
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(await newSessionCompletes(port: port), "server must survive a disconnect during STT")
    }

    @Test
    func disconnectDuringLLMLeavesServerHealthy() async throws {
        let (srv, port) = try await startServerCustom(
            transcriber: { FakeTranscriber(text: "hello there") },
            responder: { SlowResponder(deltas: ["First. ", "second clause here. ", "third. "], gapMs: 800) },
            speaker: { FastSpeaker() })
        defer { srv.stop() }
        let c1 = VoiceWebSocketClient(port: port)
        try await c1.connect()
        c1.sendControl(VoiceControl(t: "start", sampleRate: 16000))
        c1.sendAudioPCM(loudPCM(ms: 400)); c1.sendAudioPCM(silencePCM(ms: 1600))
        // Disconnect after the first token but before the stream completes (mid-LLM).
        _ = await withTimeout(4) { () -> Bool? in
            for await m in c1.messages { if case .event(let e) = m, e.t == "assistant.text_delta" { return true } }
            return false
        }
        c1.close()
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(await newSessionCompletes(port: port), "server must survive a disconnect during LLM generation")
    }

    @Test
    func disconnectWithQueuedPlaybackLeavesServerHealthy() async throws {
        // SlowSpeaker emits many chunks over time; disconnect while chunks are still queued/streaming.
        let (srv, port) = try await startServer({ SlowSpeaker() })
        defer { srv.stop() }
        let c1 = VoiceWebSocketClient(port: port)
        try await c1.connect()
        c1.sendControl(VoiceControl(t: "start", sampleRate: 16000))
        c1.sendAudioPCM(loudPCM(ms: 400)); c1.sendAudioPCM(silencePCM(ms: 1600))
        _ = await withTimeout(6) { () -> Bool? in
            var chunks = 0
            for await m in c1.messages { if case .audio = m { chunks += 1; if chunks >= 2 { return true } } }
            return false
        }
        c1.close()   // disconnect with playback still queued
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(await newSessionCompletes(port: port), "server must survive a disconnect with queued playback")
    }

    @Test
    func sessionEndWhileSpeakingStopsCleanly() async throws {
        let (srv, port) = try await startServer({ SlowSpeaker() })
        defer { srv.stop() }
        let c1 = VoiceWebSocketClient(port: port)
        try await c1.connect()
        c1.sendControl(VoiceControl(t: "start", sampleRate: 16000))
        c1.sendAudioPCM(loudPCM(ms: 400)); c1.sendAudioPCM(silencePCM(ms: 1600))
        let sawAudio = await withTimeout(6) { () -> Bool? in
            for await m in c1.messages { if case .audio = m { return true } }
            return false
        }
        c1.sendControl(VoiceControl(t: "end"))   // end the session mid-playback
        c1.close()
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(sawAudio == true)
        #expect(await newSessionCompletes(port: port), "server must accept a new session after end-while-speaking")
    }

    @Test
    func repeatedBargeInsStayHealthy() async throws {
        let (srv, port) = try await startServer({ SlowSpeaker() }, deltas: ["A long spoken answer here. "])
        defer { srv.stop() }
        let client = VoiceWebSocketClient(port: port)
        try await client.connect()
        client.sendControl(VoiceControl(t: "start", sampleRate: 16000))
        let result = await withTimeout(15) { () -> Int? in
            var cancels = 0
            client.sendAudioPCM(loudPCM(ms: 400)); client.sendAudioPCM(silencePCM(ms: 1600))
            for await m in client.messages {
                if case .audio = m {
                    // Each time it starts speaking, barge in again (explicit interrupt) — up to 3 times.
                    if cancels < 3 { client.sendControl(VoiceControl(t: "interrupt")) }
                }
                if case .event(let e) = m, e.t == "playback.cancelled" {
                    cancels += 1
                    if cancels >= 3 { return cancels }
                    // Kick off another turn after each cancel.
                    client.sendAudioPCM(loudPCM(ms: 400)); client.sendAudioPCM(silencePCM(ms: 1600))
                }
            }
            return cancels
        }
        client.close()
        #expect((result ?? 0) >= 3, "repeated barge-ins must each cancel playback without wedging the session")
    }

    @Test
    func oddLengthBinaryFrameKeepsServerHealthy() async throws {
        // Malformed *payload* (odd byte count → not whole PCM16 samples) must not crash the VAD/int16 path.
        // (Malformed WS *framing* and oversize frames are covered by VoiceWireTests.)
        let (srv, port) = try await startServer({ FastSpeaker() })
        defer { srv.stop() }
        let client = VoiceWebSocketClient(port: port)
        try await client.connect()
        client.sendControl(VoiceControl(t: "start", sampleRate: 16000))
        client.sendAudioPCM(Data([0x01, 0x02, 0x03]))   // 3 bytes — odd, sub-sample
        client.sendAudioPCM(loudPCM(ms: 400)); client.sendAudioPCM(silencePCM(ms: 1600))
        let ok = await withTimeout(8) { () -> Bool? in
            for await m in client.messages { if case .event(let e) = m, e.t == "transcript.final" { return true } }
            return false
        }
        client.close()
        #expect(ok == true, "server must tolerate an odd-length binary payload and still complete a valid turn")
    }

    @Test
    func wrongSessionControlIsIgnored() async throws {
        let (srv, port) = try await startServer({ FastSpeaker() })
        defer { srv.stop() }
        let client = VoiceWebSocketClient(port: port)
        try await client.connect()
        client.sendControl(VoiceControl(t: "start", sampleRate: 16000))
        // A control stamped with a bogus/mismatched session id must not disrupt the live session.
        client.sendControl(VoiceControl(t: "interrupt", session: "not-this-session"))
        client.sendAudioPCM(loudPCM(ms: 400)); client.sendAudioPCM(silencePCM(ms: 1600))
        let ok = await withTimeout(8) { () -> Bool? in
            for await m in client.messages { if case .event(let e) = m, e.t == "transcript.final" { return true } }
            return false
        }
        client.close()
        #expect(ok == true, "a control carrying a wrong session id must be ignored, not break the session")
    }

    @Test
    func unexpectedClientSilenceKeepsServerHealthy() async throws {
        let (srv, port) = try await startServer({ FastSpeaker() })
        defer { srv.stop() }
        let client = VoiceWebSocketClient(port: port)
        try await client.connect()
        client.sendControl(VoiceControl(t: "start", sampleRate: 16000))
        // Prolonged silence (no speech) then a real utterance, all on one connection. Pure silence must not
        // endpoint (no spurious turn); the real utterance must still complete → the VAD isn't wedged by
        // leading silence. Single message iterator (AsyncStream is single-consumer).
        client.sendAudioPCM(silencePCM(ms: 2000))
        client.sendAudioPCM(loudPCM(ms: 400)); client.sendAudioPCM(silencePCM(ms: 1600))
        let outcome = await withTimeout(10) { () -> (transcripts: Int, ended: Bool)? in
            var transcripts = 0
            for await m in client.messages {
                if case .event(let e) = m {
                    if e.t == "transcript.final" { transcripts += 1 }
                    if e.t == "tts.finished" { return (transcripts, true) }
                }
            }
            return (transcripts, false)
        }
        client.close()
        #expect(outcome?.ended == true, "a real utterance after prolonged silence must still complete a turn")
        #expect(outcome?.transcripts == 1, "prolonged leading silence must produce exactly one turn, not zero or spurious extra turns")
    }

    @Test
    func staleTurnAudioCarriesMonotonicTurnIds() async throws {
        // Turn isolation at the wire level: after a barge-in, new audio must carry a HIGHER turn id so the
        // client can drop late frames from the cancelled turn (no stale audio).
        let (srv, port) = try await startServer({ SlowSpeaker() }, deltas: ["A fairly long first answer. "])
        defer { srv.stop() }
        let client = VoiceWebSocketClient(port: port)
        try await client.connect()
        client.sendControl(VoiceControl(t: "start", sampleRate: 16000))
        let result = await withTimeout(15) { () -> (Int, Int)? in
            var firstTurn: Int? = nil
            var secondTurn: Int? = nil
            client.sendAudioPCM(loudPCM(ms: 400)); client.sendAudioPCM(silencePCM(ms: 1600))
            for await m in client.messages {
                if case .audio(let af) = m {
                    if firstTurn == nil {
                        firstTurn = Int(af.turn)
                        client.sendControl(VoiceControl(t: "interrupt"))   // barge in
                        client.sendAudioPCM(loudPCM(ms: 400)); client.sendAudioPCM(silencePCM(ms: 1600))
                    } else if let f = firstTurn, Int(af.turn) > f {
                        secondTurn = Int(af.turn)
                        return (f, secondTurn!)
                    }
                }
            }
            return nil
        }
        client.close()
        #expect(result != nil, "expected audio from two distinct turns")
        if let (a, b) = result { #expect(b > a, "post-barge-in audio must carry a higher turn id than the cancelled turn") }
    }
}
