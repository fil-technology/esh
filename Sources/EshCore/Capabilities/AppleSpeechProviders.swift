import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(Speech)
import Speech
#endif

// §4 — portable, on-device speech capabilities backed by Apple frameworks (no model download, no Python):
//   • audio.synthesizeSpeech — AVSpeechSynthesizer → a WAV Artifact.
//   • audio.transcribe       — SFSpeechRecognizer (on-device) → .textDelta.
// Both build on iOS + macOS. Speech recognition needs the host to declare its usage string and the user to
// grant permission; the provider requests authorization and, if denied/unavailable, fails honestly (never
// silently). No fabricated output.

private func optionString(_ options: ExecutionOptions, _ key: String) -> String? {
    if case .string(let s)? = options.values[key] { return s }
    return nil
}
private func optionDouble(_ options: ExecutionOptions, _ key: String) -> Double? {
    switch options.values[key] {
    case .double(let d): return d
    case .int(let i): return Double(i)
    default: return nil
    }
}

/// Ensures a `@Sendable` callback can resume its continuation exactly once.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

// MARK: - Text → speech (WAV)

public struct AppleSpeechSynthesizeProvider: CapabilityProvider {
    public let descriptor: CapabilityProviderDescriptor
    public init(id: String = "apple-speech-tts") {
        self.descriptor = CapabilityProviderDescriptor(
            id: id, capabilities: [.audioSynthesizeSpeech], acceptedInputs: [.text],
            producedOutputs: [.audio], backend: .native, streaming: false,
            structuredOutput: false, requiredPrivilege: .artifactOnly, previewMode: .none)
    }

    public func execute(_ request: ResolvedExecutionRequest,
                        context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        let text = request.request.inputs.compactMap { input -> String? in
            if case .text(let t) = input.payload { return t }
            return nil
        }.joined(separator: " ")
        let options = request.request.options
        let store = context.artifactStore
        let providerID = descriptor.id
        return AsyncThrowingStream { continuation in
            let task = Task {
                guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                    continuation.yield(.failed(message: "audio.synthesizeSpeech requires text input"))
                    continuation.finish(); return
                }
                do {
                    let wav = try await Self.synthesize(text: text, options: options)
                    let artifact = Artifact(
                        kind: .audio, mimeType: "audio/wav", files: [], entrypoint: "speech.wav",
                        generatedBy: ArtifactProvenance(providerID: providerID, capability: .audioSynthesizeSpeech))
                    let saved = try store.save(artifact, files: ["speech.wav": wav])
                    continuation.yield(.artifactProduced(saved))
                    continuation.yield(.done(finishReason: "stop"))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.yield(.failed(message: error.localizedDescription))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    #if canImport(AVFoundation)
    final class FileBox: @unchecked Sendable { var file: AVAudioFile? }

    static func synthesize(text: String, options: ExecutionOptions) async throws -> Data {
        let utterance = AVSpeechUtterance(string: text)
        if let id = optionString(options, "voice"), let voice = AVSpeechSynthesisVoice(identifier: id) {
            utterance.voice = voice
        } else if let lang = optionString(options, "language"), let voice = AVSpeechSynthesisVoice(language: lang) {
            utterance.voice = voice
        }
        if let speed = optionDouble(options, "speed") {
            utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, Float(speed)))
        }
        let synth = AVSpeechSynthesizer()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let fileBox = FileBox()
        let resume = ResumeOnce()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            synth.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    fileBox.file = nil   // close/flush the file
                    guard resume.take() else { return }
                    do {
                        let data = try Data(contentsOf: tmp)
                        try? FileManager.default.removeItem(at: tmp)
                        cont.resume(returning: data)
                    } catch { cont.resume(throwing: error) }
                    return
                }
                do {
                    if fileBox.file == nil {
                        fileBox.file = try AVAudioFile(forWriting: tmp, settings: pcm.format.settings)
                    }
                    try fileBox.file?.write(from: pcm)
                } catch {
                    guard resume.take() else { return }
                    cont.resume(throwing: error)
                }
            }
        }
    }
    #else
    static func synthesize(text: String, options: ExecutionOptions) async throws -> Data {
        throw CapabilityError.failed("speech synthesis is unavailable on this platform")
    }
    #endif
}

// MARK: - Speech → text (on-device)

public struct AppleSpeechTranscribeProvider: CapabilityProvider {
    public let descriptor: CapabilityProviderDescriptor
    private let defaultLocale: String?
    public init(id: String = "apple-speech-stt", defaultLocale: String? = nil) {
        self.defaultLocale = defaultLocale
        self.descriptor = CapabilityProviderDescriptor(
            id: id, capabilities: [.audioTranscribe], acceptedInputs: [.audio],
            producedOutputs: [.text], backend: .native, streaming: true,
            structuredOutput: false, requiredPrivilege: .artifactOnly, previewMode: .none)
    }

    public func execute(_ request: ResolvedExecutionRequest,
                        context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        let attachment = request.request.inputs.compactMap { input -> EshAttachment? in
            if case .attachment(let a) = input.payload, a.kind == .audio { return a }
            return nil
        }.first
        let language = optionString(request.request.options, "language") ?? defaultLocale
        let providerLocale = defaultLocale
        return AsyncThrowingStream { continuation in
            let task = Task {
                #if canImport(Speech)
                do {
                    guard let attachment, let audioURL = try Self.audioURL(from: attachment) else {
                        continuation.yield(.failed(message: "audio.transcribe requires an audio attachment (uri or base64)"))
                        continuation.finish(); return
                    }
                    let status = await Self.ensureAuthorized()
                    guard status == .authorized else {
                        continuation.yield(.failed(message: "speech recognition is not authorized on this device"))
                        continuation.finish(); return
                    }
                    let localeID = language ?? providerLocale ?? Locale.current.identifier
                    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)) ?? SFSpeechRecognizer(),
                          recognizer.isAvailable else {
                        continuation.yield(.failed(message: "speech recognition is unavailable on this device"))
                        continuation.finish(); return
                    }
                    let req = SFSpeechURLRecognitionRequest(url: audioURL)
                    req.shouldReportPartialResults = true
                    if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
                    try await Self.recognize(recognizer: recognizer, request: req, into: continuation)
                    continuation.yield(.done(finishReason: "stop"))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.yield(.failed(message: error.localizedDescription))
                    continuation.finish()
                }
                #else
                continuation.yield(.failed(message: "speech recognition is unavailable on this platform"))
                continuation.finish()
                #endif
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    #if canImport(Speech)
    static func ensureAuthorized() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current != .notDetermined { return current }
        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
    }

    static func audioURL(from attachment: EshAttachment) throws -> URL? {
        if let uri = attachment.uri, !uri.isEmpty {
            if let url = URL(string: uri), url.isFileURL { return url }
            return URL(fileURLWithPath: uri)
        }
        if let b64 = attachment.base64, let data = Data(base64Encoded: b64) {
            let ext = (attachment.mimeType?.hasSuffix("wav") == true) ? "wav" : "m4a"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
            try data.write(to: url)
            return url
        }
        return nil
    }

    final class TaskBox: @unchecked Sendable { var task: SFSpeechRecognitionTask? }
    final class Counter: @unchecked Sendable { var value = 0 }

    static func recognize(recognizer: SFSpeechRecognizer,
                          request: SFSpeechURLRecognitionRequest,
                          into continuation: AsyncThrowingStream<CapabilityEvent, Error>.Continuation) async throws {
        let taskBox = TaskBox()
        let emitted = Counter()
        let resume = ResumeOnce()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                taskBox.task = recognizer.recognitionTask(with: request) { result, error in
                    if let result {
                        let full = result.bestTranscription.formattedString
                        if full.count > emitted.value {
                            let delta = String(full.dropFirst(emitted.value))
                            emitted.value = full.count
                            if !delta.isEmpty { continuation.yield(.textDelta(delta)) }
                        }
                        if result.isFinal, resume.take() { cont.resume() }
                    }
                    if let error, resume.take() { cont.resume(throwing: error) }
                }
            }
        } onCancel: {
            taskBox.task?.cancel()
        }
    }
    #endif
}
