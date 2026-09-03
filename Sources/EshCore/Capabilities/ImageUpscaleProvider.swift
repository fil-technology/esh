import Foundation

// esh 2.1 UCMR — image super-resolution / upscale (image → image). A SEPARATE typed capability
// (image.upscale), not folded into a vague image.edit.
//
// Backends (Stage 4.1):
//  • DEFAULT `realesrgan-onnx` — Real-ESRGAN ONNX on onnxruntime (CoreML EP, torch-free, BSD-3). Model
//    (SceneWorks/real-esrgan-onnx, dynamic-shape x2/x4) auto-downloads to the assets root on demand.
//    LIVE-verified via /v1/execute: 512→1024 (2×, ~7.5s) and 512→2048 (4×, ~12s) on Apple M1 Pro.
//  • EXPERIMENTAL `seedvr2` — mflux SeedVR2. Broken on mflux 0.19.1 + mlx 0.32.2 (`mx.repeat` array
//    repeats); selectable via options.backend=seedvr2 for future retest, NEVER the default.
// RAM-guarded (memory floor pre-check). See 2_1_STAGE3_MODEL_PROVENANCE.md.

public enum UpscaleBackend: String, Sendable {
    case realesrganONNX = "realesrgan-onnx"   // default: Real-ESRGAN ONNX on onnxruntime (CoreML EP), torch-free
    case seedVR2 = "seedvr2"                   // experimental: mflux SeedVR2 (broken on mflux 0.19.1 + mlx 0.32.2)
}

public struct ImageUpscaleService: Sendable {
    private let bridge: MLXBridge
    public init(bridge: MLXBridge = .init()) { self.bridge = bridge }

    /// Upscale by an integer `scale` (2 or 4 for the ONNX backend). `modelDir` is where the model lives /
    /// is downloaded (under the configured assets root). Returns the produced pixel size.
    @discardableResult
    public func upscale(imagePath: String, outputPath: String, scale: Int, modelDir: String,
                        minFreeMemMB: Int?, backend: UpscaleBackend = .realesrganONNX) throws -> (width: Int, height: Int) {
        switch backend {
        case .realesrganONNX:
            let response: ONNXResponse = try bridge.run(
                command: "image-upscale-onnx",
                request: ONNXRequest(imagePath: imagePath, outputPath: outputPath, scale: scale, modelDir: modelDir, minFreeMemMB: minFreeMemMB),
                as: ONNXResponse.self)
            return (response.width, response.height)
        case .seedVR2:
            let response: SeedResponse = try bridge.run(
                command: "image-upscale",
                request: SeedRequest(imagePath: imagePath, outputPath: outputPath, resolution: nil, minFreeMemMB: minFreeMemMB, hfCache: modelDir),
                as: SeedResponse.self)
            return (response.width, response.height)
        }
    }

    private struct ONNXRequest: Codable, Sendable {
        let imagePath: String; let outputPath: String; let scale: Int; let modelDir: String; let minFreeMemMB: Int?
    }
    private struct ONNXResponse: Codable, Sendable { let outputPath: String; let width: Int; let height: Int; let scale: Int; let provider: String }
    private struct SeedRequest: Codable, Sendable {
        let imagePath: String; let outputPath: String; let resolution: Int?; let minFreeMemMB: Int?; let hfCache: String?
    }
    private struct SeedResponse: Codable, Sendable { let outputPath: String; let width: Int; let height: Int }
}

public struct ImageUpscaleProvider: CapabilityProvider {
    public typealias UpscaleFn = @Sendable (_ inputPath: String, _ outputPath: String, _ scale: Int, _ minFreeMemMB: Int?, _ backend: UpscaleBackend) throws -> (width: Int, height: Int)

    public let descriptor: CapabilityProviderDescriptor
    private let upscale: UpscaleFn

    public init(id: String = "image-upscale", upscale: @escaping UpscaleFn) {
        self.descriptor = CapabilityProviderDescriptor(
            id: id,
            capabilities: [.imageUpscale],
            acceptedInputs: [.image],
            producedOutputs: [.image],
            backend: .python,
            streaming: false,
            structuredOutput: false,
            requiredPrivilege: .artifactOnly,
            previewMode: .staticSandbox)
        self.upscale = upscale
    }

    public func execute(_ request: ResolvedExecutionRequest, context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        let req = request.request
        let upscale = self.upscale
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
                        throw CapabilityError.failed("upscaling requires an image input")
                    }
                    try StorageService().ensureAssetsAvailable(root: context.root)   // item 10: no internal-disk fallback
                    let (inPath, isTemp) = try VisionUnderstandProvider.materialize(image, root: context.root)
                    if isTemp { tempPaths.append(inPath) }
                    let scale = TextToSVGProvider.intOption(req, "scale") ?? 4
                    let minFreeMemMB = TextToSVGProvider.intOption(req, "minFreeMemMB")
                    let backend = UpscaleBackend(rawValue: VideoUnderstandingProvider.stringOption(req, "backend") ?? "") ?? .realesrganONNX
                    try FileManager.default.createDirectory(at: context.root.tempURL, withIntermediateDirectories: true)
                    let outPath = context.root.tempURL.appendingPathComponent("upscale-\(UUID().uuidString).png").path
                    tempPaths.append(outPath)

                    cont.yield(.status("upscaling image (\(backend.rawValue), \(scale)×)"))
                    let size = try upscale(inPath, outPath, scale, minFreeMemMB, backend)
                    let bytes = try Data(contentsOf: URL(fileURLWithPath: outPath))
                    let artifact = Artifact(
                        kind: .image, mimeType: "image/png", entrypoint: "result.png",
                        metadata: ["width": .int(size.width), "height": .int(size.height), "scale": .int(scale)],
                        generatedBy: ArtifactProvenance(providerID: providerID, modelID: req.model, capability: .imageUpscale),
                        validation: .valid, preview: .staticSandbox)
                    let saved = try context.artifactStore.save(artifact, files: ["result.png": bytes])
                    cont.yield(.planResolved(ExecutionPlan.single(
                        capability: req.capability, inputModalities: [.image], outputModality: .image,
                        providerID: providerID, modelID: req.model, backend: .python,
                        rationale: ["Single-provider super-resolution (\(backend.rawValue), \(scale)× via onnxruntime CoreML)."])))
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
