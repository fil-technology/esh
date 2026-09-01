import Foundation
import EshCore

/// Shared wiring for the server's speech-to-text (STT) endpoint. Decodes the browser's base64 audio
/// payload to a temp file, runs on-device transcription via `SpeechToTextService`, and returns the
/// text. The STT model comes from the request, else the user's configured `stt_model`, else the
/// built-in parakeet default. Local only — no cloud.
enum SpeechEndpointSupport {
    static func transcribeClosure() -> (@Sendable (OpenAIAudioTranscriptionRequest) async throws -> OpenAIAudioTranscriptionResponse) {
        { request in
            guard let data = Data(base64Encoded: sanitizedBase64(request.audio)), data.isEmpty == false else {
                throw OpenAICompatibleError.invalidRequest("Audio payload was not valid base64-encoded audio.")
            }
            let rawExt = (request.filename as NSString?)?.pathExtension ?? ""
            let ext = rawExt.isEmpty ? "wav" : rawExt
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("esh-stt-\(UUID().uuidString).\(ext)")
            try data.write(to: tempURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let configuredModel = (try? EshConfigStore().load())?.defaults.sttModel
            let model = request.model ?? configuredModel
            let text = try SpeechToTextService().transcribe(
                audioPath: tempURL.path,
                model: model,
                language: request.language
            )
            return OpenAIAudioTranscriptionResponse(
                text: text,
                model: model ?? SpeechToTextService.defaultModel,
                language: request.language
            )
        }
    }

    /// Accept both raw base64 and `data:...;base64,<payload>` strings.
    private static func sanitizedBase64(_ value: String) -> String {
        if let commaIndex = value.firstIndex(of: ","), value.hasPrefix("data:") {
            return String(value[value.index(after: commaIndex)...])
        }
        return value
    }
}
