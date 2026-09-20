import Foundation

// rc.22 — normalized, provider-agnostic speech transcript with timing. Reusable outside Esh Studio (subtitle
// export, seek-from-transcript, playback highlighting). Timing is only ever surfaced when the backend really
// produces it — never fabricated. A plain-text-only backend yields a valid transcript with `segments: []`.
// Serialized as JSON inside an Artifact of kind `.transcript` (see ArtifactKind), so it rides the existing
// artifact transport/persistence.

public struct Transcript: Codable, Hashable, Sendable {
    /// The full transcript text (always present — the compatibility surface).
    public var text: String
    /// Timed segments, in order. Empty when the backend provides no timing.
    public var segments: [TranscriptSegment]
    /// BCP-47 locale of the recognition, when known (e.g. "en-US").
    public var locale: String?

    public init(text: String, segments: [TranscriptSegment] = [], locale: String? = nil) {
        self.text = text
        self.segments = segments
        self.locale = locale
    }
}

public struct TranscriptSegment: Codable, Hashable, Sendable {
    public var text: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    /// Word-level timing when the backend provides it (e.g. Whisper). `nil` for segment-only backends
    /// (Apple Speech) — do not synthesize.
    public var words: [TranscriptWord]?

    public init(text: String, startTime: TimeInterval, endTime: TimeInterval, words: [TranscriptWord]? = nil) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.words = words
    }
}

public struct TranscriptWord: Codable, Hashable, Sendable {
    public var text: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval

    public init(text: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
    }
}

public extension Transcript {
    /// The transcript file name inside a `.transcript` artifact.
    static let artifactFileName = "transcript.json"

    /// JSON bytes for embedding in an Artifact.
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Decode from a `.transcript` artifact's JSON bytes.
    static func decode(from data: Data) throws -> Transcript {
        try JSONDecoder().decode(Transcript.self, from: data)
    }

    /// Build from segment-level timing (start = `timestamp`, end = `timestamp + duration`). Word timing is
    /// unknown for segment-only backends (Apple Speech) → `words = nil`, never synthesized. Passing an empty
    /// `segments` array yields a valid text-only transcript. Pure + Speech-framework-free (testable).
    static func fromTimedSegments(
        fullText: String, locale: String?,
        segments timed: [(text: String, timestamp: TimeInterval, duration: TimeInterval)]
    ) -> Transcript {
        let segs = timed.map {
            TranscriptSegment(text: $0.text, startTime: $0.timestamp, endTime: $0.timestamp + $0.duration, words: nil)
        }
        return Transcript(text: fullText, segments: segs, locale: locale)
    }
}
