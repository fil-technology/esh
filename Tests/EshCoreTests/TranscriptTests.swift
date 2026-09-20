import Foundation
import Testing
@testable import EshCore

// rc.22 B — timestamped transcript. Deterministic + Speech-framework-free (the SFSpeech→tuples mapping is
// tested; the recognizer itself is device-gated).

@Suite struct TranscriptTests {
    @Test func mappingProducesSegmentStartEndAndNilWords() {
        let timed = [(text: "hello", timestamp: 0.0, duration: 0.5),
                     (text: "world", timestamp: 0.6, duration: 0.4)]
        let t = Transcript.fromTimedSegments(fullText: "hello world", locale: "en-US", segments: timed)
        #expect(t.text == "hello world")
        #expect(t.locale == "en-US")
        #expect(t.segments.count == 2)
        #expect(t.segments[0].startTime == 0.0 && t.segments[0].endTime == 0.5)   // end = timestamp + duration
        #expect(t.segments[1].startTime == 0.6)
        #expect(abs(t.segments[1].endTime - 1.0) < 1e-9)
        #expect(t.segments.allSatisfy { $0.words == nil })                        // segment-only → never fabricate words
    }

    @Test func plainTextOnlyIsValidWithEmptySegments() {
        let t = Transcript.fromTimedSegments(fullText: "just text", locale: nil, segments: [])
        #expect(t.text == "just text")
        #expect(t.segments.isEmpty)                                               // valid, no timing invented
    }

    @Test func jsonRoundTrip() throws {
        let original = Transcript(text: "hi there", segments: [
            TranscriptSegment(text: "hi", startTime: 0, endTime: 0.3,
                              words: [TranscriptWord(text: "hi", startTime: 0, endTime: 0.3)]),
            TranscriptSegment(text: "there", startTime: 0.35, endTime: 0.9, words: nil),
        ], locale: "en-US")
        let decoded = try Transcript.decode(from: original.jsonData())
        #expect(decoded == original)
    }

    @Test func roundTripThroughArtifactStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("esh-tr-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileArtifactStore(rootURL: dir)
        let transcript = Transcript.fromTimedSegments(fullText: "one two", locale: "en-US",
            segments: [(text: "one", timestamp: 0, duration: 0.4), (text: "two", timestamp: 0.5, duration: 0.4)])
        let artifact = Artifact(kind: .transcript, mimeType: "application/json", files: [],
                                entrypoint: Transcript.artifactFileName,
                                generatedBy: ArtifactProvenance(providerID: "apple-speech-stt", capability: .audioTranscribe))
        let saved = try store.save(artifact, files: [Transcript.artifactFileName: transcript.jsonData()])
        #expect(saved.kind == .transcript)
        let bytes = try #require(try store.data(id: saved.id, file: Transcript.artifactFileName))
        #expect(try Transcript.decode(from: bytes) == transcript)
    }

    @Test func textAndTranscriptArtifactCoexistInResult() throws {
        // Compatibility contract: ExecutionResult.text is preserved AND the timed transcript rides as an
        // additive output — a text-only consumer ignores outputs; a timing-aware consumer reads the artifact.
        let transcript = Transcript.fromTimedSegments(fullText: "hello world", locale: "en-US",
            segments: [(text: "hello", timestamp: 0, duration: 0.5)])
        let artifact = Artifact(kind: .transcript, mimeType: "application/json", files: [],
                                entrypoint: Transcript.artifactFileName,
                                generatedBy: ArtifactProvenance(providerID: "apple-speech-stt", capability: .audioTranscribe))
        let result = ExecutionResult(capability: .audioTranscribe, text: "hello world", outputs: [artifact])
        #expect(result.text == "hello world")                     // .textDelta/text surface unchanged
        #expect(result.outputs.count == 1 && result.outputs[0].kind == .transcript)
        _ = transcript
    }
}
