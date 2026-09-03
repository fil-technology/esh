import Foundation

// esh 2.1 UCMR, Stage 2 — background removal / segmentation (image → image). The first image-OUTPUT
// provider: proves a typed IMAGE artifact end-to-end (acceptance Extension C, edit-image class). Uses
// rembg (MIT) via the bridge; rembg + onnxruntime are an optional dependency.

/// Thin wrapper over the `image-segment` bridge op (mirrors SpeechToTextService/VisionUnderstandingService).
public struct SegmentationService: Sendable {
    private let bridge: MLXBridge
    public init(bridge: MLXBridge = .init()) { self.bridge = bridge }

    /// Remove the background from `imagePath`, writing an RGBA PNG to `outputPath`. Returns its size.
    @discardableResult
    public func removeBackground(imagePath: String, outputPath: String) throws -> (width: Int, height: Int) {
        let response: Response = try bridge.run(
            command: "image-segment",
            request: Request(imagePath: imagePath, outputPath: outputPath),
            as: Response.self)
        return (response.width, response.height)
    }

    private struct Request: Codable, Sendable { let imagePath: String; let outputPath: String }
    private struct Response: Codable, Sendable { let outputPath: String; let width: Int; let height: Int }
}

public struct SegmentationProvider: CapabilityProvider {
    public typealias RemoveBackgroundFn = @Sendable (_ inputPath: String, _ outputPath: String) throws -> (width: Int, height: Int)

    public let descriptor: CapabilityProviderDescriptor
    private let removeBackground: RemoveBackgroundFn

    public init(id: String = "segmentation", removeBackground: @escaping RemoveBackgroundFn) {
        self.descriptor = CapabilityProviderDescriptor(
            id: id,
            capabilities: [.imageSegment, .imageEdit],
            acceptedInputs: [.image],
            producedOutputs: [.image],
            backend: .python,
            streaming: false,
            structuredOutput: false,
            requiredPrivilege: .artifactOnly,
            previewMode: .staticSandbox)
        self.removeBackground = removeBackground
    }

    public func execute(_ request: ResolvedExecutionRequest, context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        let req = request.request
        let removeBackground = self.removeBackground
        let providerID = descriptor.id
        return AsyncThrowingStream { cont in
            let task = Task {
                var tempPaths: [String] = []
                defer { for p in tempPaths { try? FileManager.default.removeItem(atPath: p) } }
                do {
                    guard let image = req.inputs.compactMap({ input -> EshAttachment? in
                        if case .attachment(let a) = input.payload, a.kind == .image { return a }
                        return nil
                    }).first else {
                        throw CapabilityError.failed("background removal requires an image input")
                    }
                    let (inPath, isTemp) = try VisionUnderstandProvider.materialize(image, root: context.root)
                    if isTemp { tempPaths.append(inPath) }
                    try FileManager.default.createDirectory(at: context.root.tempURL, withIntermediateDirectories: true)
                    let outPath = context.root.tempURL.appendingPathComponent("seg-\(UUID().uuidString).png").path
                    tempPaths.append(outPath)

                    cont.yield(.status("removing background"))
                    let size = try removeBackground(inPath, outPath)
                    let bytes = try Data(contentsOf: URL(fileURLWithPath: outPath))
                    let artifact = Artifact(
                        kind: .image, mimeType: "image/png", entrypoint: "result.png",
                        metadata: ["width": .int(size.width), "height": .int(size.height)],
                        generatedBy: ArtifactProvenance(providerID: providerID, modelID: req.model, capability: .imageSegment),
                        validation: .valid, preview: .staticSandbox)
                    let saved = try context.artifactStore.save(artifact, files: ["result.png": bytes])
                    cont.yield(.artifactProduced(saved))
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
}
