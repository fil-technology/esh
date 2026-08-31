import Foundation
import Testing
@testable import EshCore

@Suite
struct SpeechToTextServiceTests {
    @Test
    func missingAudioFileFailsClearly() {
        let service = SpeechToTextService()
        #expect(throws: (any Error).self) {
            _ = try service.transcribe(audioPath: "/tmp/definitely-not-here-\(UUID().uuidString).wav")
        }
    }

    @Test
    func defaultModelIsAnOnDeviceMLXModel() {
        #expect(SpeechToTextService.defaultModel.contains("parakeet"))
    }
}
