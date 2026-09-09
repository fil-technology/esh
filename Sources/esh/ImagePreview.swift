import Foundation
import ImageIO
import CoreGraphics
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

// Convert an uploaded photo to a browser-renderable JPEG. iPhone photos are HEIC, which Chromium-based
// browsers can't decode in an <img> — so the composer/chat showed a broken thumbnail even though the edit
// worked (the Python bridge normalizes HEIC server-side). macOS decodes HEIC natively via ImageIO, so this
// gives the web UI a JPEG data URL to display (EXIF orientation applied, downscaled). It's also fine to edit
// from — the edit path re-normalizes/caps whatever it receives.
enum ImagePreview {
    /// Decode `base64` (any format ImageIO reads, incl. HEIC/HEIF), apply EXIF orientation, downscale the long
    /// side to `maxSide`, and return a `data:image/jpeg;base64,…` URL. nil if it can't be decoded.
    static func normalizedJPEGDataURL(fromBase64 base64: String, maxSide: Int = 1600) -> String? {
        guard let data = Data(base64Encoded: base64), !data.isEmpty else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // bake in EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxSide)
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let out = NSMutableData()
        let jpegType: CFString
        #if canImport(UniformTypeIdentifiers)
        if #available(macOS 11.0, *) { jpegType = UTType.jpeg.identifier as CFString }
        else { jpegType = "public.jpeg" as CFString }
        #else
        jpegType = "public.jpeg" as CFString
        #endif
        guard let dest = CGImageDestinationCreateWithData(out, jpegType, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return "data:image/jpeg;base64," + (out as Data).base64EncodedString()
    }
}
