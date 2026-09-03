import Foundation
import Testing
@testable import EshCore

@Suite
struct AudioDiarizationProviderTests {
    private func context() -> (ExecutionContext, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("esh-diar-\(UUID().uuidString)", isDirectory: true)
        return (ExecutionContext(root: PersistenceRoot(rootURL: dir),
                                 artifactStore: FileArtifactStore(rootURL: dir.appendingPathComponent("artifacts"))), dir)
    }

    private func audioInput() -> ExecutionRequest {
        ExecutionRequest(capability: .audioDiarize,
                         inputs: [.attachment(EshAttachment(kind: .audio, mimeType: "audio/wav", base64: Data([1,2,3]).base64EncodedString()))],
                         output: .init(modality: .json))
    }

    @Test
    func producesSpeakerSegmentsAndPipelinePlanWithTranscript() async throws {
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        let provider = AudioDiarizationProvider(
            diarize: { _, _ in [DiarizationSegment(start: 0, end: 1.5, speaker: "speaker_0"),
                                DiarizationSegment(start: 1.5, end: 3.0, speaker: "speaker_1")] },
            transcribe: { _ in "hello there" })
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [provider]), context: ctx)
        let result = try await svc.executeCollecting(audioInput())
        let json = try #require(result.text)
        #expect(json.contains("speaker_0") && json.contains("speaker_1"))
        #expect(json.contains("\"speakers\":2") || json.contains("\"speakers\" : 2"))
        #expect(json.contains("hello there"))                 // STT merged
        #expect(json.lowercased().contains("clusters, not identities"))  // honest note
        let plan = try #require(result.plan)
        #expect(plan.steps.contains { $0.providerID == "speech-to-text" })
    }

    @Test
    func requiresAudioInput() async {
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        let provider = AudioDiarizationProvider(diarize: { _, _ in [] })
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [provider]), context: ctx)
        await #expect(throws: CapabilityError.self) {
            _ = try await svc.executeCollecting(ExecutionRequest(capability: .audioDiarize, inputs: [.text("x")], output: .init(modality: .json)))
        }
    }

    @Test
    func dispatchedForDiarizeAudioToJSON() {
        let reg = CapabilityRegistry(providers: [AudioDiarizationProvider(diarize: { _, _ in [] })])
        #expect(reg.providers(for: .audioDiarize, inputs: [.audio], output: .json).count == 1)
        #expect(reg.providers(for: .audioDiarize, inputs: [.image], output: .json).isEmpty)
    }
}
