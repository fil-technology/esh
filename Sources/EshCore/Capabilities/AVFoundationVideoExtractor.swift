import Foundation
#if canImport(AVFoundation)
import AVFoundation
import CoreMedia
import ImageIO
import CoreGraphics
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

// esh 2.1 UCMR, Stage 3 — the real media backend for video.understand, using Apple's AVFoundation +
// ImageIO. No ffmpeg or other external binary: packaging stays clean and the pipeline runs offline on a
// clean Mac. Audio is decoded to 16 kHz mono WAV (what the parakeet STT bridge expects).
public struct AVFoundationVideoExtractor: VideoMediaExtractor {
    public init() {}

    public func metadata(path: String) async throws -> VideoMetadata {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let duration: CMTime
        do { duration = try await asset.load(.duration) }
        catch { throw CapabilityError.failed("could not open video (corrupt or unsupported): \(error.localizedDescription)") }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds >= 0 else { throw CapabilityError.failed("video has no readable duration (corrupt file)") }

        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard let vtrack = videoTracks.first else {
            throw CapabilityError.failed("no video track found (unsupported container or codec)")
        }
        let size = (try? await vtrack.load(.naturalSize)) ?? .zero
        let fps = (try? await vtrack.load(.nominalFrameRate)) ?? 0
        var codec: String?
        if let formats = try? await vtrack.load(.formatDescriptions), let fmt = formats.first {
            let sub = CMFormatDescriptionGetMediaSubType(fmt)
            codec = Self.fourCC(sub)
        }
        return VideoMetadata(durationSeconds: seconds, width: Int(abs(size.width)), height: Int(abs(size.height)),
                             nominalFrameRate: Double(fps), codec: codec, hasAudio: !audioTracks.isEmpty)
    }

    public func extractKeyframes(path: String, timestampsSeconds: [Double], into dir: URL) async throws -> [String] {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        // Cap decode cost: downscale very large frames (the VLM sees ~a few hundred px anyway).
        gen.maximumSize = CGSize(width: 768, height: 768)

        var out: [String] = []
        for (i, ts) in timestampsSeconds.enumerated() {
            try Task.checkCancellation()
            let time = CMTime(seconds: max(0, ts), preferredTimescale: 600)
            let cg: CGImage
            do { cg = try await gen.image(at: time).image }
            catch {
                // A single unreadable timestamp shouldn't fail the whole pipeline; skip it.
                continue
            }
            let url = dir.appendingPathComponent("frame-\(i).png")
            guard Self.writePNG(cg, to: url) else { continue }
            out.append(url.path)
        }
        return out
    }

    public func extractAudio(path: String, into dir: URL) async throws -> String? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let track = (try? await asset.loadTracks(withMediaType: .audio))?.first else { return nil }

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else {
            throw CapabilityError.failed("could not read audio track: \(reader.error?.localizedDescription ?? "unknown")")
        }

        var pcm = Data()
        while reader.status == .reading {
            try Task.checkCancellation()
            guard let sample = output.copyNextSampleBuffer(),
                  let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            if CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer) == kCMBlockBufferNoErr,
               let dataPointer {
                pcm.append(UnsafeBufferPointer(start: UnsafePointer(dataPointer).withMemoryRebound(to: UInt8.self, capacity: length) { $0 }, count: length))
            }
            CMSampleBufferInvalidate(sample)
        }
        if reader.status == .failed { throw CapabilityError.failed("audio decode failed: \(reader.error?.localizedDescription ?? "unknown")") }
        guard !pcm.isEmpty else { return nil }

        let url = dir.appendingPathComponent("audio.wav")
        try Self.writeWAV(pcm16: pcm, sampleRate: 16_000, channels: 1, to: url)
        return url.path
    }

    // MARK: - Helpers

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF), UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        let s = String(bytes: bytes, encoding: .ascii) ?? ""
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        let type: CFString
        #if canImport(UniformTypeIdentifiers)
        type = UTType.png.identifier as CFString
        #else
        type = "public.png" as CFString
        #endif
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    /// Write a minimal 16-bit PCM WAV (RIFF) from interleaved little-endian PCM samples.
    static func writeWAV(pcm16: Data, sampleRate: Int, channels: Int, to url: URL) throws {
        let byteRate = sampleRate * channels * 2
        let blockAlign = channels * 2
        var header = Data()
        func appendLE32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { header.append(contentsOf: $0) } }
        func appendLE16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { header.append(contentsOf: $0) } }
        header.append(contentsOf: Array("RIFF".utf8))
        appendLE32(UInt32(36 + pcm16.count))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        appendLE32(16)                       // PCM fmt chunk size
        appendLE16(1)                        // PCM
        appendLE16(UInt16(channels))
        appendLE32(UInt32(sampleRate))
        appendLE32(UInt32(byteRate))
        appendLE16(UInt16(blockAlign))
        appendLE16(16)                       // bits per sample
        header.append(contentsOf: Array("data".utf8))
        appendLE32(UInt32(pcm16.count))
        var file = header
        file.append(pcm16)
        try file.write(to: url, options: .atomic)
    }
}
#endif
