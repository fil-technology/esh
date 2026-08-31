import Foundation

/// On-device speech-to-text (M10) via mlx_audio, invoked through the MLX bridge. Symmetric with the
/// MLX TTS path: local, no cloud. The model (e.g. parakeet) is fetched/cached by mlx_audio.
public struct SpeechToTextService: Sendable {
    /// A sensible on-device default verified to transcribe accurately on Apple Silicon.
    public static let defaultModel = "mlx-community/parakeet-tdt-0.6b-v2"

    private let bridge: MLXBridge

    public init(bridge: MLXBridge = .init()) {
        self.bridge = bridge
    }

    public func transcribe(audioPath: String, model: String? = nil, language: String? = nil) throws -> String {
        let absolute = URL(fileURLWithPath: audioPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: absolute.path) else {
            throw StoreError.notFound("Audio file not found: \(audioPath)")
        }
        let response: TranscribeResponse = try bridge.run(
            command: "mlx-transcribe",
            request: TranscribeRequest(
                audioPath: absolute.path,
                modelPath: model ?? Self.defaultModel,
                language: language
            ),
            as: TranscribeResponse.self
        )
        return response.text
    }
}

private struct TranscribeRequest: Codable, Sendable {
    let audioPath: String
    let modelPath: String
    let language: String?
}

private struct TranscribeResponse: Codable, Sendable {
    let text: String
}
