import Foundation
import Testing
@testable import EshCore

@Suite
struct VideoUnderstandingProviderTests {
    // A mock extractor: no real decode. `hasAudio`/`audioPath` drive the audio branch.
    struct MockExtractor: VideoMediaExtractor {
        var duration: Double
        var hasAudio: Bool
        var frameCount: Int
        var throwOnMetadata: Bool = false
        func metadata(path: String) async throws -> VideoMetadata {
            if throwOnMetadata { throw CapabilityError.failed("could not open video (corrupt or unsupported)") }
            return VideoMetadata(durationSeconds: duration, width: 640, height: 480, nominalFrameRate: 30, codec: "avc1", hasAudio: hasAudio)
        }
        func extractKeyframes(path: String, timestampsSeconds: [Double], into dir: URL) async throws -> [String] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return (0..<min(frameCount, timestampsSeconds.count)).map { i in
                let u = dir.appendingPathComponent("frame-\(i).png"); try? Data([1]).write(to: u); return u.path
            }
        }
        func extractAudio(path: String, into dir: URL) async throws -> String? {
            guard hasAudio else { return nil }
            let u = dir.appendingPathComponent("audio.wav"); try? Data([1]).write(to: u); return u.path
        }
    }

    private func context() -> (ExecutionContext, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("esh-vid-\(UUID().uuidString)", isDirectory: true)
        return (ExecutionContext(root: PersistenceRoot(rootURL: dir),
                                 artifactStore: FileArtifactStore(rootURL: dir.appendingPathComponent("artifacts"))), dir)
    }

    private func provider(_ ex: MockExtractor, sawTranscribe: @escaping @Sendable () -> Void = {}) -> VideoUnderstandingProvider {
        VideoUnderstandingProvider(
            extractor: ex,
            describeFrame: { _, _ in "a person waves at the camera" },
            transcribe: { _ in sawTranscribe(); return "hello everyone welcome" },
            fuse: { req in
                // Echo evidence so we can assert fusion consumed captions + transcript.
                let user = req.messages.last?.text ?? ""
                let hasCaption = user.contains("waves at the camera")
                let hasTranscript = user.contains("welcome")
                return ExternalInferenceResponse(modelID: "fusion-llm", backend: .mlx, integration: .init(mode: "direct"),
                    outputText: "ANSWER caption=\(hasCaption) transcript=\(hasTranscript)",
                    metrics: .init(contextTokens: 10))
            })
    }

    @Test
    func shortClipWithSpeechFusesVisualAndAudioAndExposesPipelinePlan() async throws {
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [provider(.init(duration: 2, hasAudio: true, frameCount: 1))]), context: ctx)
        let result = try await svc.executeCollecting(ExecutionRequest(
            capability: .videoUnderstand,
            inputs: [.attachment(EshAttachment(kind: .video, mimeType: "video/mp4", base64: Data([1,2,3]).base64EncodedString())),
                     .text("What happens and what is said?")],
            output: .text))
        #expect(result.text?.contains("caption=true") == true)
        #expect(result.text?.contains("transcript=true") == true)
        // Canonical multi-provider ExecutionPlan is exposed on the result.
        let plan = try #require(result.plan)
        #expect(plan.isPipeline)
        #expect(plan.steps.contains { $0.providerID == "speech-to-text" })
        #expect(plan.steps.contains { $0.providerID.hasPrefix("image-understand") })
        #expect(plan.rationale.contains { $0.lowercased().contains("sampled-frame") })
    }

    @Test
    func clipWithoutAudioSkipsSTTStep() async throws {
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        let ex = MockExtractor(duration: 3, hasAudio: false, frameCount: 2)
        let p = VideoUnderstandingProvider(
            extractor: ex,
            describeFrame: { _, _ in "a bird flies across the sky" },
            // No audio → this must never be reached; if it is, the transcript would appear and fail below.
            transcribe: { _ in "UNEXPECTED-TRANSCRIPT" },
            fuse: { req in ExternalInferenceResponse(modelID: "m", backend: .mlx, integration: .init(mode: "direct"),
                                                     outputText: (req.messages.last?.text.contains("UNEXPECTED-TRANSCRIPT") ?? false) ? "LEAK" : "ok",
                                                     metrics: .init(contextTokens: 1)) })
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [p]), context: ctx)
        let result = try await svc.executeCollecting(ExecutionRequest(
            capability: .videoUnderstand,
            inputs: [.attachment(EshAttachment(kind: .video, mimeType: "video/mp4", base64: Data([1]).base64EncodedString()))],
            output: .text))
        #expect(result.text == "ok")   // transcribe never ran → no leaked transcript
        let plan = try #require(result.plan)
        #expect(!plan.steps.contains { $0.providerID == "speech-to-text" })
        #expect(plan.rationale.contains { $0.lowercased().contains("no usable audio") })
    }

    @Test
    func requiresAVideoInput() async {
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [provider(.init(duration: 2, hasAudio: true, frameCount: 1))]), context: ctx)
        await #expect(throws: CapabilityError.self) {
            _ = try await svc.executeCollecting(ExecutionRequest(
                capability: .videoUnderstand, inputs: [.text("no video here")], output: .text))
        }
    }

    @Test
    func corruptVideoSurfacesACleanError() async {
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [provider(.init(duration: 0, hasAudio: false, frameCount: 0, throwOnMetadata: true))]), context: ctx)
        await #expect(throws: CapabilityError.self) {
            _ = try await svc.executeCollecting(ExecutionRequest(
                capability: .videoUnderstand,
                inputs: [.attachment(EshAttachment(kind: .video, mimeType: "video/mp4", base64: Data([1]).base64EncodedString()))],
                output: .text))
        }
    }

    @Test
    func samplerIsDurationAwareAndCapped() {
        #expect(VideoFrameSampler.sampleTimestamps(durationSeconds: 0).count == 1)
        #expect(VideoFrameSampler.sampleTimestamps(durationSeconds: 2, maxFrames: 8).count == 1)   // 2s/2 = 1
        #expect(VideoFrameSampler.sampleTimestamps(durationSeconds: 10, maxFrames: 8).count == 5)  // 10s/2 = 5
        #expect(VideoFrameSampler.sampleTimestamps(durationSeconds: 600, maxFrames: 8).count == 8) // capped
        // Timestamps are within (0, duration) and increasing.
        let ts = VideoFrameSampler.sampleTimestamps(durationSeconds: 8, maxFrames: 4)
        #expect(ts == ts.sorted())
        #expect(ts.allSatisfy { $0 > 0 && $0 < 8 })
    }
}
