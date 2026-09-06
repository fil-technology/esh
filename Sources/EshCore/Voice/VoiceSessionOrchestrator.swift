import Foundation

// esh 2.1 — Voice 2.1 conversational orchestrator (server-owned, spec §3/§4/§9/§11/§14/§15).
//
// This actor is the canonical runtime: it drives the VoiceSession state machine, runs a turn (STT → inference
// → phrase-chunked TTS with audible output starting on the first phrase), enforces the bounded context, and
// implements barge-in — genuine user speech during thinking/speaking cancels the in-flight turn, clears
// playback, and returns to listening with no stale audio. It depends only on the VoiceTranscriber/Responder/
// Speaker seams, so it is fully unit-testable with fakes (no hardware) and wired to the real speech backends
// via thin adapters. It owns runtime state; the web/client is a view of the emitted VoiceEvent stream.
public actor VoiceSessionOrchestrator {
    public let id: VoiceSessionID
    public let config: VoiceSessionConfig

    private let transcriber: VoiceTranscriber
    private let responder: VoiceResponder
    private let speaker: VoiceSpeaker
    private let chunker: VoicePhraseChunker
    private let now: @Sendable () -> Double

    private var state: VoiceSessionState = .idle
    private var context: VoiceConversationContext
    private var turnTask: Task<Void, Never>?
    private var metrics = VoiceTurnMetrics()

    private let continuation: AsyncStream<VoiceEvent>.Continuation
    /// The event stream a transport/client consumes. Unbounded buffering so emits never block the runtime.
    public nonisolated let events: AsyncStream<VoiceEvent>

    public init(id: VoiceSessionID = UUID().uuidString,
                config: VoiceSessionConfig = .init(),
                transcriber: VoiceTranscriber,
                responder: VoiceResponder,
                speaker: VoiceSpeaker,
                now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.id = id
        self.config = config
        self.transcriber = transcriber
        self.responder = responder
        self.speaker = speaker
        self.chunker = VoicePhraseChunker()
        self.now = now
        self.context = VoiceConversationContext(maxTurns: config.maxContextTurns, maxCharacters: config.maxContextCharacters)
        let (stream, cont) = AsyncStream.makeStream(of: VoiceEvent.self, bufferingPolicy: .unbounded)
        self.events = stream
        self.continuation = cont
    }

    // MARK: - Public control surface

    /// Begin the session: emit `session.started` and open the mic (→ listening).
    public func start() {
        guard state == .idle else { return }
        emit(.sessionStarted(id))
        setState(.listening)
    }

    /// A live input RMS level (0…1) for the meter. Only meaningful while listening.
    public func inputLevel(_ level: Double) {
        guard state == .listening || state == .speechDetected else { return }
        emit(.inputLevel(max(0, min(1, level))))
    }

    /// VAD detected speech onset. While listening → arm the turn. While thinking/speaking → barge-in.
    public func inputSpeechStarted() {
        switch state {
        case .listening:
            setState(.speechDetected)
            emit(.vadSpeechStarted)
        case .idle, .ended, .speechDetected, .error, .interrupted:
            break
        case .transcribing, .thinking, .speaking:
            handleBargeIn()
        }
    }

    /// The endpoint was reached (trailing silence): submit the captured utterance and run a turn.
    public func submitUtterance(_ audio: VoiceAudioInput) {
        guard state == .speechDetected || state == .listening else { return }
        emit(.vadSpeechEnded)
        setState(.transcribing)
        metrics = VoiceTurnMetrics()
        metrics.speechEndedAt = now()
        let audioCopy = audio
        turnTask = Task { [weak self] in
            await self?.runTurn(audioCopy)
        }
    }

    /// Explicitly clear the bounded conversation context (spec §11) without ending the session.
    public func resetContext() { context.reset() }

    /// End the session: cancel any in-flight turn, emit `session.ended`, close the stream. Terminal + idempotent.
    public func end(reason: String = "client_ended") {
        guard state != .ended else { return }
        turnTask?.cancel()
        turnTask = nil
        setState(.ended)
        emit(.sessionEnded(reason: reason))
        continuation.finish()
    }

    // MARK: - Introspection (for the Execution Inspector / tests)

    public func currentState() -> VoiceSessionState { state }
    public func contextTurns() -> [VoiceTurn] { context.turns }
    public func lastTurnMetrics() -> VoiceTurnMetrics { metrics }
    /// Await the in-flight turn (test/inspection convenience). Returns immediately if none.
    public func awaitTurn() async { await turnTask?.value }

    // MARK: - Barge-in (spec §9)

    private func handleBargeIn() {
        guard config.interruption.bargeInEnabled else { return }
        metrics.bargeInDetectedAt = now()
        emit(.interruptionDetected)
        setState(.interrupted)
        turnTask?.cancel()          // the in-flight turn observes cancellation and goes silent
        turnTask = nil
        emit(.playbackCancelled)    // this method owns the teardown events; the turn emits nothing further
        metrics.playbackStoppedAt = now()
        setState(.listening)
        setState(.speechDetected)
        emit(.vadSpeechStarted)
    }

    // MARK: - Turn execution

    private func runTurn(_ audio: VoiceAudioInput) async {
        do {
            // STT
            let text = try await transcriber.transcribe(audio, language: config.language, model: config.sttModel)
            if Task.isCancelled { return }
            let finalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            metrics.finalTranscriptAt = now()
            guard !finalText.isEmpty else { setState(.listening); return }   // heard nothing intelligible
            emit(.transcriptFinal(finalText))
            context.append(VoiceTurn(role: .user, text: finalText))

            // Inference (streamed) + low-latency phrase-chunked TTS
            if Task.isCancelled { return }
            setState(.thinking)
            emit(.assistantThinkingStarted)
            var buffer = ""
            var full = ""
            var spoke = false
            let stream = responder.respond(context: context.turns, language: config.language, model: config.inferenceModel)
            for try await delta in stream {
                if Task.isCancelled { return }
                guard !delta.isEmpty else { continue }
                if metrics.firstTokenAt == nil { metrics.firstTokenAt = now() }
                full += delta
                emit(.assistantTextDelta(delta))
                for phrase in chunker.ingest(delta, into: &buffer) {
                    if Task.isCancelled { return }
                    try await speak(phrase, spoke: &spoke)
                }
            }
            if Task.isCancelled { return }
            let finalReply = full.trimmingCharacters(in: .whitespacesAndNewlines)
            emit(.assistantTextFinal(finalReply))
            if let rest = chunker.flush(&buffer) {
                try await speak(rest, spoke: &spoke)
            }
            if Task.isCancelled { return }
            if spoke { emit(.ttsFinished) }
            if !finalReply.isEmpty { context.append(VoiceTurn(role: .assistant, text: finalReply)) }
            setState(.listening)
        } catch is CancellationError {
            return   // barge-in / end already emitted teardown
        } catch {
            if Task.isCancelled { return }
            emit(.sessionError(message: error.localizedDescription, recoverable: true))
            setState(.listening)   // recover — the session survives a single-turn failure
        }
    }

    /// Speak one phrase; the first audio chunk of the turn flips to `speaking` and stamps first-audible latency.
    private func speak(_ phrase: String, spoke: inout Bool) async throws {
        let stream = speaker.speak(phrase, language: config.language, model: config.ttsModel)
        for try await chunk in stream {
            if Task.isCancelled { return }
            if !spoke {
                spoke = true
                setState(.speaking)
                emit(.ttsStarted)
                let t = now()
                metrics.firstAudioChunkAt = t
                metrics.firstAudibleAt = t
            }
            emit(.ttsAudioChunk(chunk))
        }
    }

    // MARK: - Emission

    private func setState(_ new: VoiceSessionState) {
        guard state != new else { return }
        state = new
        continuation.yield(.stateChanged(new))
    }

    private func emit(_ event: VoiceEvent) {
        continuation.yield(event)
    }
}
