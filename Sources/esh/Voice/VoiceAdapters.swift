import Foundation
import EshCore

// esh 2.1 — Voice 2.1 live-path adapters. These bind the canonical VoiceSession seams (VoiceTranscriber /
// VoiceResponder / VoiceSpeaker, defined in EshCore) to the REAL local backends, without duplicating them:
//   STT  → SpeechRuntimeManager (warm speech runtime; whole-file today — honest, see notes)
//   LLM  → ExternalInferenceService.inferStream (real streamed deltas; Scheduler-selectable model)
//   TTS  → AudioSpeechGenerator (TTSMLX; buffered per phrase → one audio chunk, so audible output begins on
//          the first phrase). Streaming TTS (TTSMLX.synthesizeStream) is the next refinement.
// Composed by VoiceSessionFactory. The orchestration (state machine, barge-in, cancellation, metrics, bounded
// context) stays in EshCore; these are thin bindings only.

/// STT adapter over the warm SpeechRuntimeManager. Writes the utterance bytes to a temp file (the backend
/// takes a path) and transcribes. Whole-file today; a streaming decoder would additionally emit partials.
public struct SpeechRuntimeTranscriber: VoiceTranscriber {
    private let speech: SpeechRuntimeManager
    public init(lifecycleManager: RuntimeLifecycleManager? = nil) {
        self.speech = SpeechRuntimeManager(lifecycleManager: lifecycleManager)
    }
    public func transcribe(_ audio: VoiceAudioInput, language: String?, model: String?) async throws -> String {
        let ext = audio.format.isEmpty ? "wav" : audio.format
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("esh-voice-stt-\(UUID().uuidString).\(ext)")
        try audio.bytes.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            return try await speech.transcribe(audioPath: tmp.path, model: model, language: language)
        } catch {
            // Never regress below the one-shot path if the warm worker can't run.
            return try SpeechToTextService().transcribe(audioPath: tmp.path, model: model, language: language)
        }
    }
}

/// Inference adapter over ExternalInferenceService: streams real assistant text deltas for the bounded
/// context. A concise spoken-style system instruction keeps replies short enough for low-latency TTS.
public struct LanguageResponder: VoiceResponder {
    private let inference: ExternalInferenceService
    private let resolveModel: @Sendable (_ pinned: String?) -> String?
    private let systemPrompt: String

    public init(inference: ExternalInferenceService,
                resolveModel: @escaping @Sendable (_ pinned: String?) -> String?,
                systemPrompt: String = "You are a voice assistant. Reply in one or two short, natural spoken sentences. No markdown, no lists.") {
        self.inference = inference
        self.resolveModel = resolveModel
        self.systemPrompt = systemPrompt
    }

    public func respond(context: [VoiceTurn], language: String?, model: String?) -> AsyncThrowingStream<String, Error> {
        let chosen = model ?? resolveModel(model)
        var messages: [ExternalInferenceMessage] = [.init(role: .system, text: systemPrompt)]
        for t in context {
            messages.append(.init(role: t.role == .user ? .user : .assistant, text: t.text))
        }
        let request = ExternalInferenceRequest(
            model: chosen,
            messages: messages,
            generation: GenerationConfig(maxTokens: 200, temperature: 0.7))
        // inferStream already yields raw text deltas and propagates cancellation into generation.
        return inference.inferStream(request: request)
    }
}

/// TTS adapter over AudioSpeechGenerator. Synthesizes one phrase to a temp WAV and yields it as a single
/// final audio chunk (buffered). Cancellation between phrases stops further synthesis promptly; the
/// orchestrator flips to `speaking` on this first chunk. Streaming PCM (TTSMLX.synthesizeStream) is future work.
public struct BufferedTTSSpeaker: VoiceSpeaker {
    private let workingDirectory: URL
    private let lifecycleManager: RuntimeLifecycleManager?
    public init(workingDirectory: URL = FileManager.default.temporaryDirectory,
                lifecycleManager: RuntimeLifecycleManager? = nil) {
        self.workingDirectory = workingDirectory
        self.lifecycleManager = lifecycleManager
    }
    public func speak(_ text: String, language: String?, model: String?) -> AsyncThrowingStream<VoiceAudioChunk, Error> {
        let dir = workingDirectory
        let pool = lifecycleManager
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if Task.isCancelled { continuation.finish(); return }
                    let out = dir.appendingPathComponent("esh-voice-tts-\(UUID().uuidString).wav")
                    let result = try await AudioSpeechGenerator.synthesize(
                        .init(text: text, model: model, voice: nil, language: language,
                              outputURL: out, forceOverwrite: true, profile: nil, maxTokens: nil,
                              temperature: nil, topP: nil, hfToken: nil),
                        currentDirectoryURL: dir,
                        lifecycleManager: pool)
                    if Task.isCancelled { try? FileManager.default.removeItem(at: out); continuation.finish(); return }
                    let bytes = (try? Data(contentsOf: result.url)) ?? Data()
                    try? FileManager.default.removeItem(at: result.url)
                    continuation.yield(VoiceAudioChunk(bytes: bytes, sampleRate: result.sampleRate, format: "wav", isFinal: true))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
