import Foundation

// Portable attachment/MIME helpers. Extracted from VisionUnderstandProvider (esh iOS M1) so
// portable providers (e.g. AppleVisionOCRProvider) can resolve attachments without depending on
// the macOS-only Python-bridge vision provider.
public enum AttachmentIO {
    /// Resolve an image attachment to a local file path. `uri` file paths are used as-is; inline base64
    /// is written to a temp file (caller deletes temps). Returns (path, isTemporary).
    static func materialize(_ attachment: EshAttachment, root: PersistenceRoot) throws -> (String, Bool) {
        if let uri = attachment.uri, !uri.isEmpty {
            let path = uri.hasPrefix("file://") ? URL(string: uri)?.path ?? uri : uri
            guard FileManager.default.fileExists(atPath: path) else {
                throw CapabilityError.failed("image not found at \(path)")
            }
            return (path, false)
        }
        guard let b64 = attachment.base64, let data = Data(base64Encoded: Self.stripDataURLPrefix(b64)) else {
            throw CapabilityError.failed("image attachment has no readable content")
        }
        let ext = Self.ext(for: attachment.mimeType)
        try FileManager.default.createDirectory(at: root.tempURL, withIntermediateDirectories: true)
        let url = root.tempURL.appendingPathComponent("vlm-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        return (url.path, true)
    }

    static func stripDataURLPrefix(_ s: String) -> String {
        if s.hasPrefix("data:"), let comma = s.firstIndex(of: ",") { return String(s[s.index(after: comma)...]) }
        return s
    }

    static func ext(for mime: String?) -> String {
        switch mime {
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/webp": return "webp"
        case "image/gif": return "gif"
        // Audio (diarization/STT materialize through here too): a correct extension matters — soundfile/
        // librosa infer the container from it, so a WAV named ".png" fails to decode.
        case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/m4a", "audio/x-m4a": return "m4a"
        case "audio/flac": return "flac"
        case "audio/ogg": return "ogg"
        default:
            if let mime, mime.hasPrefix("audio/") { return "wav" }
            return "png"
        }
    }
}
