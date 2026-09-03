import Foundation
#if canImport(Vision)
import Vision
import ImageIO
#endif

// esh 2.1 UCMR, Stage 2 — OCR via Apple's Vision framework (VNRecognizeTextRequest). Zero dependency,
// zero download, on-device, mature — the plain-text OCR baseline on the Apple stack esh already uses.
// A VLM-based doc parser (e.g. PaddleOCR-VL) can be added later for tables/layout as a separate provider.

public struct AppleVisionOCRProvider: CapabilityProvider {
    public let descriptor: CapabilityProviderDescriptor

    public init(id: String = "apple-vision-ocr") {
        self.descriptor = CapabilityProviderDescriptor(
            id: id,
            capabilities: [.imageOCR],
            acceptedInputs: [.image],
            producedOutputs: [.text],
            backend: .appleVision,
            streaming: false,
            structuredOutput: false,
            requiredPrivilege: .artifactOnly,
            previewMode: .none)
    }

    public func execute(_ request: ResolvedExecutionRequest, context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        let req = request.request
        return AsyncThrowingStream { cont in
            let task = Task {
                var tempPaths: [String] = []
                defer { for p in tempPaths { try? FileManager.default.removeItem(atPath: p) } }
                do {
                    var paths: [String] = []
                    for input in req.inputs {
                        if case .attachment(let a) = input.payload, a.kind == .image {
                            let (path, isTemp) = try VisionUnderstandProvider.materialize(a, root: context.root)
                            paths.append(path); if isTemp { tempPaths.append(path) }
                        }
                    }
                    guard !paths.isEmpty else { throw CapabilityError.failed("OCR requires at least one image input") }
                    cont.yield(.status("recognizing text in \(paths.count) image(s)"))
                    var pages: [String] = []
                    for path in paths { pages.append(try Self.recognizeText(atPath: path)) }
                    let text = pages.joined(separator: "\n\n")
                    if !text.isEmpty { cont.yield(.textDelta(text)) }
                    cont.yield(.done(finishReason: "stop"))
                    cont.finish()
                } catch {
                    cont.yield(.failed(message: error.localizedDescription))
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// Run Vision text recognition on an image file, returning recognized lines joined by newlines.
    static func recognizeText(atPath path: String) throws -> String {
        #if canImport(Vision)
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CapabilityError.failed("could not read image at \(path)")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
        #else
        throw CapabilityError.failed("Apple Vision OCR is only available on macOS.")
        #endif
    }
}
