import Foundation
import Testing
@testable import EshCore

struct ModelCapabilitiesTests {
    @Test
    func decodesLegacyModelSpecAsTextModel() throws {
        let data = Data(
            #"""
            {
              "id": "legacy",
              "displayName": "Legacy Text Model",
              "backend": "mlx",
              "source": {
                "kind": "huggingFace",
                "reference": "mlx-community/legacy"
              },
              "localPath": "/tmp/legacy",
              "architectureFingerprint": "qwen2",
              "variant": null
            }
            """#.utf8
        )

        let spec = try JSONCoding.decoder.decode(ModelSpec.self, from: data)

        #expect(spec.task == .text)
        #expect(spec.inputModalities == [.text])
        #expect(spec.outputModalities == [.text])
        #expect(spec.capabilities.supports(capability: .chat))
        #expect(spec.capabilities.supports(capability: .completion))
    }

    @Test
    func encodesAudioCapabilities() throws {
        let spec = ModelSpec(
            id: "kokoro",
            displayName: "Kokoro",
            backend: .mlx,
            source: ModelSource(kind: .huggingFace, reference: "example/kokoro"),
            task: .audio,
            inputModalities: [.text],
            outputModalities: [.audio],
            capabilities: ModelCapabilities(
                audio: AudioCapabilities(
                    supportsTTS: true,
                    supportedOutputFormats: ["wav"],
                    voices: [AudioVoice(id: "af_sarah", displayName: "Sarah", language: "en")]
                )
            )
        )

        let data = try JSONCoding.encoder.encode(spec)
        let decoded = try JSONCoding.decoder.decode(ModelSpec.self, from: data)

        #expect(decoded.task == .audio)
        #expect(decoded.outputModalities == [.audio])
        #expect(decoded.capabilities.supports(capability: .tts))
        #expect(!decoded.capabilities.supports(capability: .stt))
        #expect(decoded.capabilities.audio?.voices.first?.id == "af_sarah")
    }
}
