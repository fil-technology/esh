import Foundation
import Testing
@testable import EshCore

// esh 2.1 — Voice 2.1 runtime-core tests. Exercise the canonical VoiceSession state machine, event ordering,
// barge-in (interrupt cancels the in-flight turn, clears playback, no stale audio, resumes listening), bounded
// context, and phrase chunking — all with fakes, no hardware.

// MARK: - Fakes

private struct FakeTranscriber: VoiceTranscriber {
    let text: String
    var error: Error? = nil
    func transcribe(_ audio: VoiceAudioInput, language: String?, model: String?) async throws -> String {
        if let error { throw error }
        return text
    }
}

private struct FakeResponder: VoiceResponder {
    let deltas: [String]
    func respond(context: [VoiceTurn], language: String?, model: String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            for d in deltas { cont.yield(d) }
            cont.finish()
        }
    }
}

/// Yields one chunk per phrase immediately (fast, for normal-turn tests).
private struct FastSpeaker: VoiceSpeaker {
    func speak(_ text: String, language: String?, model: String?) -> AsyncThrowingStream<VoiceAudioChunk, Error> {
        AsyncThrowingStream { cont in
            cont.yield(VoiceAudioChunk(bytes: Data([0x1, 0x2]), sampleRate: 24000, format: "wav", isFinal: true))
            cont.finish()
        }
    }
}

/// Emits a first chunk then keeps "playing" (sleeping) until cancelled — lets a test barge in mid-playback.
private struct SlowSpeaker: VoiceSpeaker {
    func speak(_ text: String, language: String?, model: String?) -> AsyncThrowingStream<VoiceAudioChunk, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                cont.yield(VoiceAudioChunk(bytes: Data([0x1]), sampleRate: 24000))
                do {
                    for _ in 0..<200 {
                        try Task.checkCancellation()
                        try await Task.sleep(nanoseconds: 20_000_000) // 20ms
                        cont.yield(VoiceAudioChunk(bytes: Data([0x2]), sampleRate: 24000))
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}

private func makeOrchestrator(text: String = "hello there",
                              deltas: [String] = ["Hi. ", "How are you? "],
                              speaker: VoiceSpeaker = FastSpeaker(),
                              transcribeError: Error? = nil,
                              config: VoiceSessionConfig = .init()) -> VoiceSessionOrchestrator {
    VoiceSessionOrchestrator(
        id: "test-session",
        config: config,
        transcriber: FakeTranscriber(text: text, error: transcribeError),
        responder: FakeResponder(deltas: deltas),
        speaker: speaker)
}

private let sampleAudio = VoiceAudioInput(bytes: Data([0xAA, 0xBB]), format: "wav", sampleRate: 16000)

@Suite
struct VoiceSessionTests {

    // MARK: Bounded context (spec §11)

    @Test
    func contextEnforcesTurnLimitAndReset() {
        var ctx = VoiceConversationContext(maxTurns: 3, maxCharacters: 10_000)
        for i in 0..<5 { ctx.append(VoiceTurn(role: .user, text: "turn\(i)")) }
        #expect(ctx.turns.count == 3)
        #expect(ctx.turns.first?.text == "turn2")   // oldest dropped
        ctx.reset()
        #expect(ctx.turns.isEmpty)
    }

    @Test
    func contextEnforcesCharacterBudgetAndIgnoresEmpty() {
        // maxCharacters has a 200-char sane floor; use budget 200 with 150-char turns.
        var ctx = VoiceConversationContext(maxTurns: 100, maxCharacters: 200)
        ctx.append(VoiceTurn(role: .user, text: String(repeating: "a", count: 150)))
        ctx.append(VoiceTurn(role: .assistant, text: String(repeating: "b", count: 150)))
        #expect(ctx.totalCharacters <= 200)         // oldest dropped to fit the budget
        #expect(ctx.turns.count == 1)
        ctx.append(VoiceTurn(role: .user, text: "   "))  // whitespace-only ignored
        #expect(ctx.turns.count == 1)
    }

    // MARK: Phrase chunker (spec §8 low-latency pumping)

    @Test
    func phraseChunkerSplitsOnBoundariesAndFlushes() {
        let chunker = VoicePhraseChunker(minChunkCharacters: 3)
        var buf = ""
        var chunks = chunker.ingest("Hello world. How are", into: &buf)
        #expect(chunks == ["Hello world."])
        chunks = chunker.ingest(" you? Fine", into: &buf)
        #expect(chunks == ["How are you?"])
        #expect(chunker.flush(&buf) == "Fine")
        #expect(chunker.flush(&buf) == nil)          // nothing left
    }

    // MARK: Normal turn (spec §3/§4/§14)

    @Test
    func normalTurnEmitsOrderedEventsAndUpdatesContext() async {
        let orch = makeOrchestrator()
        await orch.start()
        await orch.inputSpeechStarted()
        await orch.submitUtterance(sampleAudio)
        await orch.awaitTurn()

        let state = await orch.currentState()
        #expect(state == .listening)                 // ready for the next turn
        let turns = await orch.contextTurns()
        #expect(turns.count == 2)
        #expect(turns[0].role == .user && turns[0].text == "hello there")
        #expect(turns[1].role == .assistant)
        let m = await orch.lastTurnMetrics()
        #expect(m.speechEndedAt != nil && m.finalTranscriptAt != nil && m.firstTokenAt != nil && m.firstAudibleAt != nil)

        await orch.end()
        var names: [String] = []
        for await e in orch.events { names.append(e.name) }
        // Key milestones present and correctly ordered.
        for required in ["session.started", "vad.speech_started", "vad.speech_ended", "transcript.final",
                         "assistant.thinking_started", "assistant.text_delta", "tts.started",
                         "tts.audio_chunk", "assistant.text_final", "tts.finished", "session.ended"] {
            #expect(names.contains(required), "missing \(required)")
        }
        #expect(names.firstIndex(of: "transcript.final")! < names.firstIndex(of: "assistant.thinking_started")!)
        #expect(names.firstIndex(of: "tts.started")! < names.firstIndex(of: "tts.finished")!)
        #expect(names.firstIndex(of: "assistant.thinking_started")! < names.firstIndex(of: "tts.started")!)
    }

    // MARK: Barge-in (spec §9)

    @Test
    func bargeInCancelsPlaybackAndResumesListening() async {
        let orch = makeOrchestrator(deltas: ["Let me explain in detail. "], speaker: SlowSpeaker())
        var collected: [String] = []
        let consumer = Task {
            for await e in orch.events {
                collected.append(e.name)
                if case .ttsStarted = e { await orch.inputSpeechStarted() }  // user barges in mid-playback
                if case .playbackCancelled = e { break }
            }
            return collected
        }
        await orch.start()
        await orch.inputSpeechStarted()
        await orch.submitUtterance(sampleAudio)
        let names = await consumer.value

        #expect(names.contains("interruption.detected"))
        #expect(names.contains("playback.cancelled"))
        #expect(!names.contains("tts.finished"))            // the interrupted turn never completed playback
        // Interruption ordering: detected before cancelled.
        #expect(names.firstIndex(of: "interruption.detected")! < names.firstIndex(of: "playback.cancelled")!)

        let state = await orch.currentState()
        #expect(state == .speechDetected)                   // armed for the new (barged-in) utterance
        let turns = await orch.contextTurns()
        #expect(turns.count == 1 && turns[0].role == .user) // interrupted assistant reply NOT committed
        let m = await orch.lastTurnMetrics()
        #expect(m.bargeInDetectedAt != nil && m.playbackStoppedAt != nil)
        #expect((m.bargeInToStoppedMs ?? -1) >= 0)
        await orch.end()
    }

    // MARK: Empty transcript → no assistant turn, back to listening

    @Test
    func emptyTranscriptReturnsToListeningWithoutReplying() async {
        let orch = makeOrchestrator(text: "   ")
        await orch.start()
        await orch.inputSpeechStarted()
        await orch.submitUtterance(sampleAudio)
        await orch.awaitTurn()
        #expect(await orch.currentState() == .listening)
        #expect(await orch.contextTurns().isEmpty)
        await orch.end()
    }

    // MARK: Error recovery (spec §15) — a failed turn surfaces an error but the session survives

    @Test
    func transcriberErrorSurfacesRecoverableErrorAndSurvives() async {
        struct STTDown: Error {}
        let orch = makeOrchestrator(transcribeError: STTDown())
        await orch.start()
        await orch.inputSpeechStarted()
        await orch.submitUtterance(sampleAudio)
        await orch.awaitTurn()
        #expect(await orch.currentState() == .listening)   // recovered, not stuck in error/ended
        await orch.end()
        var sawError = false
        for await e in orch.events { if case .sessionError(_, let recoverable) = e { sawError = true; #expect(recoverable) } }
        #expect(sawError)
    }

    // MARK: end() is terminal + idempotent

    @Test
    func endIsTerminalAndClosesStream() async {
        let orch = makeOrchestrator()
        await orch.start()
        await orch.end()
        await orch.end()                                   // idempotent, no crash
        #expect(await orch.currentState() == .ended)
        var names: [String] = []
        for await e in orch.events { names.append(e.name) } // finishes because the stream was closed
        #expect(names.contains("session.ended"))
        #expect(names.filter { $0 == "session.ended" }.count == 1)
    }
}
