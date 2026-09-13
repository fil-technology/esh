import Foundation

// Portable video media contracts + adaptive frame sampler. Extracted from
// VideoUnderstandingProvider (esh iOS M1) so the Apple-shared AVFoundation extractor and the
// portable pipeline types build on iOS without the macOS-only (Python-bridge) understanding provider.

public struct VideoMetadata: Sendable, Equatable {
    public var durationSeconds: Double
    public var width: Int
    public var height: Int
    public var nominalFrameRate: Double
    public var codec: String?
    public var hasAudio: Bool
    public init(durationSeconds: Double, width: Int, height: Int, nominalFrameRate: Double, codec: String?, hasAudio: Bool) {
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
        self.nominalFrameRate = nominalFrameRate
        self.codec = codec
        self.hasAudio = hasAudio
    }
}

/// Media operations behind a protocol so the pipeline is testable without real decode, and so the codec
/// backend (AVFoundation) can be swapped without touching the pipeline. Implementations must throw a
/// CapabilityError for corrupt/unsupported inputs.
public protocol VideoMediaExtractor: Sendable {
    func metadata(path: String) async throws -> VideoMetadata
    /// Extract one frame per timestamp (seconds); returns the written PNG file paths (temp; caller deletes).
    func extractKeyframes(path: String, timestampsSeconds: [Double], into dir: URL) async throws -> [String]
    /// Extract the audio track to a WAV file; returns its path, or nil when there is no audio track.
    func extractAudio(path: String, into dir: URL) async throws -> String?
}

/// Duration-aware adaptive frame sampling: more frames for longer clips up to a cap, evenly spread and
/// centered in their segment. Pure + deterministic → unit-testable. (Scene-change detection can refine
/// this later; today it is honest uniform sampling.)
public enum VideoFrameSampler {
    public static func sampleTimestamps(durationSeconds: Double, maxFrames: Int = 8, minSecondsPerFrame: Double = 2.0) -> [Double] {
        guard durationSeconds.isFinite, durationSeconds > 0 else { return [0] }
        let byDuration = Int((durationSeconds / max(0.5, minSecondsPerFrame)).rounded(.up))
        let count = max(1, min(maxFrames, byDuration))
        let segment = durationSeconds / Double(count)
        return (0..<count).map { (Double($0) + 0.5) * segment }
    }
}
