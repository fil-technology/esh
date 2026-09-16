import Foundation
#if canImport(CoreImage)
import CoreImage
#endif
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(Metal)
import Metal
#endif
#if canImport(MetalFX)
import MetalFX
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

// §3 — native, in-process image upscaling. No Python, no model download. Primary path is Apple's MetalFX
// spatial scaler (`MTLFXSpatialScaler`, macOS 13 / iOS 16) — an on-device learned upscaler — with a robust
// Core Image Lanczos fallback for devices/inputs where MetalFX is unavailable, so the capability always
// produces a correct higher-resolution artifact. Input: an image attachment + an optional `scale` (or
// `width`/`height`) in `options`. Output: a PNG `Artifact` at the requested size.
public struct AppleImageUpscaleProvider: CapabilityProvider {
    public let descriptor: CapabilityProviderDescriptor
    public init(id: String = "apple-image-upscale") {
        self.descriptor = CapabilityProviderDescriptor(
            id: id, capabilities: [.imageUpscale], acceptedInputs: [.image],
            producedOutputs: [.image], backend: .native, streaming: false,
            structuredOutput: false, requiredPrivilege: .artifactOnly, previewMode: .none)
    }

    public func execute(_ request: ResolvedExecutionRequest,
                        context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        let attachment = request.request.inputs.compactMap { input -> EshAttachment? in
            if case .attachment(let a) = input.payload, a.kind == .image { return a }
            return nil
        }.first
        let options = request.request.options.values
        let store = context.artifactStore
        let providerID = descriptor.id
        return AsyncThrowingStream { continuation in
            let task = Task {
                #if canImport(CoreImage) && canImport(CoreGraphics)
                guard let attachment, let cgImage = Self.loadCGImage(from: attachment) else {
                    continuation.yield(.failed(message: "image.upscale requires an image attachment (uri or base64)"))
                    continuation.finish(); return
                }
                let (outW, outH) = Self.targetSize(for: cgImage, options: options)
                guard outW > 0, outH > 0 else {
                    continuation.yield(.failed(message: "image.upscale needs a positive scale (or width/height) in options"))
                    continuation.finish(); return
                }
                do {
                    try Task.checkCancellation()
                    let (png, engine) = try Self.upscale(cgImage, toWidth: outW, height: outH)
                    try Task.checkCancellation()
                    let artifact = Artifact(
                        kind: .image, mimeType: "image/png", files: [], entrypoint: "upscaled.png",
                        generatedBy: ArtifactProvenance(providerID: providerID + "." + engine, capability: .imageUpscale))
                    let saved = try store.save(artifact, files: ["upscaled.png": png])
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
                continuation.yield(.failed(message: "image upscaling is unavailable on this platform"))
                continuation.finish()
                #endif
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    #if canImport(CoreImage) && canImport(CoreGraphics)
    enum UpscaleError: Error, LocalizedError {
        case renderFailed
        var errorDescription: String? {
            switch self {
            case .renderFailed: return "could not render the upscaled image"
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

    /// Resolve the output size from `options`: explicit `width`/`height` win; otherwise `scale` (default 2×).
    static func targetSize(for image: CGImage, options: [String: JSONValue]) -> (Int, Int) {
        func number(_ key: String) -> Double? {
            switch options[key] {
            case .int(let i): return Double(i)
            case .double(let d): return d
            default: return nil
            }
        }
        if let w = number("width"), let h = number("height"), w > 0, h > 0 {
            return (Int(w.rounded()), Int(h.rounded()))
        }
        let scale = number("scale").map { max(1.0, min($0, 8.0)) } ?? 2.0
        return (Int((Double(image.width) * scale).rounded()), Int((Double(image.height) * scale).rounded()))
    }

    /// Returns (PNG data, engine tag). Tries MetalFX, then falls back to Core Image Lanczos.
    static func upscale(_ image: CGImage, toWidth outW: Int, height outH: Int) throws -> (Data, String) {
        #if canImport(Metal) && canImport(MetalFX)
        if #available(macOS 13.0, iOS 16.0, *),
           let up = try? metalFXUpscale(image, toWidth: outW, height: outH) {
            return (up, "metalfx")
        }
        #endif
        return (try lanczosUpscale(image, toWidth: outW, height: outH), "lanczos")
    }

    /// Core Image Lanczos resample + mild sharpen — universal, artifact-free, no model.
    static func lanczosUpscale(_ image: CGImage, toWidth outW: Int, height outH: Int) throws -> Data {
        let ci = CIImage(cgImage: image)
        let sx = Double(outW) / Double(image.width)
        let sy = Double(outH) / Double(image.height)
        let scaled = ci
            .applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: sx,
                kCIInputAspectRatioKey: sy / sx
            ])
            .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.4])
        let ctx = CIContext()
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let rect = CGRect(x: 0, y: 0, width: outW, height: outH)
        guard let png = ctx.pngRepresentation(of: scaled.cropped(to: rect), format: .RGBA8,
                                               colorSpace: colorSpace, options: [:]) else {
            throw UpscaleError.renderFailed
        }
        return png
    }

    #if canImport(Metal) && canImport(MetalFX)
    @available(macOS 13.0, iOS 16.0, *)
    static func metalFXUpscale(_ image: CGImage, toWidth outW: Int, height outH: Int) throws -> Data {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { throw UpscaleError.renderFailed }
        let inW = image.width, inH = image.height
        let fmt: MTLPixelFormat = .rgba8Unorm

        // Input texture, filled from the CGImage via a CoreImage render (sRGB -> linear-agnostic RGBA8).
        let inDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: inW, height: inH, mipmapped: false)
        inDesc.usage = [.shaderRead, .shaderWrite]
        inDesc.storageMode = .managed
        guard let inTex = device.makeTexture(descriptor: inDesc) else { throw UpscaleError.renderFailed }
        let ciCtx = CIContext(mtlDevice: device)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        ciCtx.render(CIImage(cgImage: image), to: inTex,
                     commandBuffer: nil, bounds: CGRect(x: 0, y: 0, width: inW, height: inH), colorSpace: colorSpace)

        let outDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: outW, height: outH, mipmapped: false)
        outDesc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        outDesc.storageMode = .managed
        guard let outTex = device.makeTexture(descriptor: outDesc) else { throw UpscaleError.renderFailed }

        let scalerDesc = MTLFXSpatialScalerDescriptor()
        scalerDesc.inputWidth = inW; scalerDesc.inputHeight = inH
        scalerDesc.outputWidth = outW; scalerDesc.outputHeight = outH
        scalerDesc.colorTextureFormat = fmt
        scalerDesc.outputTextureFormat = fmt
        scalerDesc.colorProcessingMode = .perceptual
        guard let scaler = scalerDesc.makeSpatialScaler(device: device) else { throw UpscaleError.renderFailed }
        scaler.colorTexture = inTex
        scaler.outputTexture = outTex

        guard let cmd = queue.makeCommandBuffer() else { throw UpscaleError.renderFailed }
        scaler.encode(commandBuffer: cmd)
        // Sync the managed output back to CPU so we can read it.
        if let blit = cmd.makeBlitCommandEncoder() {
            blit.synchronize(resource: outTex)
            blit.endEncoding()
        }
        cmd.commit()
        cmd.waitUntilCompleted()
        if cmd.error != nil { throw UpscaleError.renderFailed }

        // Read the output texture back into a CGImage and encode PNG.
        let bytesPerRow = outW * 4
        var raw = [UInt8](repeating: 0, count: bytesPerRow * outH)
        outTex.getBytes(&raw, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, outW, outH), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(raw) as CFData) else { throw UpscaleError.renderFailed }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let cg = CGImage(width: outW, height: outH, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo,
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent) else { throw UpscaleError.renderFailed }
        return try encodePNG(cg)
    }

    static func encodePNG(_ cg: CGImage) throws -> Data {
        let data = NSMutableData()
        let type: CFString
        #if canImport(UniformTypeIdentifiers)
        type = UTType.png.identifier as CFString
        #else
        type = "public.png" as CFString
        #endif
        guard let dest = CGImageDestinationCreateWithData(data, type, 1, nil) else { throw UpscaleError.renderFailed }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { throw UpscaleError.renderFailed }
        return data as Data
    }
    #endif
    #endif
}
