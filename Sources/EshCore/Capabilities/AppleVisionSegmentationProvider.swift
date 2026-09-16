import Foundation
#if canImport(Vision)
import Vision
#endif
#if canImport(CoreImage)
import CoreImage
#endif
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// §3/§10 — native, in-process background removal / foreground segmentation via Apple's Vision framework
// (`VNGenerateForegroundInstanceMaskRequest`, iOS 17 / macOS 14). No Python, no model download; replaces the
// Python `rembg` path for the SDK. Input: an image attachment. Output: a PNG `Artifact` with the background
// removed (transparent). If no foreground subject is detected, it fails honestly rather than returning the
// original silently.
public struct AppleVisionSegmentationProvider: CapabilityProvider {
    public let descriptor: CapabilityProviderDescriptor
    public init(id: String = "apple-vision-segmentation") {
        self.descriptor = CapabilityProviderDescriptor(
            id: id, capabilities: [.imageSegment], acceptedInputs: [.image],
            producedOutputs: [.image], backend: .appleVision, streaming: false,
            structuredOutput: false, requiredPrivilege: .artifactOnly, previewMode: .none)
    }

    public func execute(_ request: ResolvedExecutionRequest,
                        context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        let attachment = request.request.inputs.compactMap { input -> EshAttachment? in
            if case .attachment(let a) = input.payload, a.kind == .image { return a }
            return nil
        }.first
        let store = context.artifactStore
        let providerID = descriptor.id
        return AsyncThrowingStream { continuation in
            let task = Task {
                #if canImport(Vision) && canImport(CoreImage)
                guard let attachment, let cgImage = Self.loadCGImage(from: attachment) else {
                    continuation.yield(.failed(message: "image.segment requires an image attachment (uri or base64)"))
                    continuation.finish(); return
                }
                do {
                    let png = try Self.removeBackground(cgImage)
                    let artifact = Artifact(
                        kind: .image, mimeType: "image/png", files: [], entrypoint: "segmented.png",
                        generatedBy: ArtifactProvenance(providerID: providerID, capability: .imageSegment))
                    let saved = try store.save(artifact, files: ["segmented.png": png])
                    continuation.yield(.artifactProduced(saved))
                    continuation.yield(.done(finishReason: "stop"))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.yield(.failed(message: error.localizedDescription))
                    continuation.finish()
                }
                #else
                continuation.yield(.failed(message: "image segmentation is unavailable on this platform"))
                continuation.finish()
                #endif
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    #if canImport(Vision) && canImport(CoreImage)
    enum SegmentationError: Error, LocalizedError {
        case noSubject
        case renderFailed
        var errorDescription: String? {
            switch self {
            case .noSubject: return "no foreground subject was detected in the image"
            case .renderFailed: return "could not render the segmented image"
            }
        }
    }

    static func loadCGImage(from attachment: EshAttachment) -> CGImage? {
        let data: Data?
        if let uri = attachment.uri, !uri.isEmpty {
            let url = (URL(string: uri).flatMap { $0.isFileURL ? $0 : nil }) ?? URL(fileURLWithPath: uri)
            data = try? Data(contentsOf: url)
        } else if let b64 = attachment.base64 {
            data = Data(base64Encoded: b64)
        } else {
            data = nil
        }
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return image
    }

    static func removeBackground(_ cgImage: CGImage) throws -> Data {
        guard #available(iOS 17.0, macOS 14.0, *) else { throw SegmentationError.renderFailed }
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw SegmentationError.noSubject
        }
        let masked = try observation.generateMaskedImage(
            ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: false)
        let ciImage = CIImage(cvPixelBuffer: masked)
        let ctx = CIContext()
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let png = ctx.pngRepresentation(of: ciImage, format: .RGBA8, colorSpace: colorSpace, options: [:]) else {
            throw SegmentationError.renderFailed
        }
        return png
    }
    #endif
}
