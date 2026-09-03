import Foundation

// esh 2.1 UCMR, Stage 3 — image super-resolution / upscale (image → image) via mflux's SeedVR2 diffusion
// upscaler through the `image-upscale` bridge op. A SEPARATE typed capability (image.upscale), not folded
// into a vague image.edit, per the spec. mflux optional; RAM-guarded (VAE tiling + memory floor).
//
// STATUS (live-validated 2026-09-03): the provider WIRING is verified end-to-end — model asset download
// routed to the external SSD, RAM guard active, and a clean typed error on failure. The SeedVR2 BACKEND
// itself is currently EXPERIMENTAL / non-functional on mflux 0.19.1 + mlx 0.32.2: mflux's SeedVR2
// attention calls `mx.repeat(x, mx.array(counts), axis=…)` (array repeats) which this mlx rejects
// (repeats must be Int), so a real upscale run fails upstream. Revisit with a newer mflux, or add a
// Real-ESRGAN ONNX backend (onnxruntime is already present) — see 2_1_STAGE3_MODEL_PROVENANCE.md.

public struct ImageUpscaleService: Sendable {
    private let bridge: MLXBridge
    public init(bridge: MLXBridge = .init()) { self.bridge = bridge }

    @discardableResult
    public func upscale(imagePath: String, outputPath: String, resolution: Int?, minFreeMemMB: Int?, hfCache: String?) throws -> (width: Int, height: Int) {
        let response: Response = try bridge.run(
            command: "image-upscale",
            request: Request(imagePath: imagePath, outputPath: outputPath, resolution: resolution, minFreeMemMB: minFreeMemMB, hfCache: hfCache),
            as: Response.self)
        return (response.width, response.height)
    }

    private struct Request: Codable, Sendable {
        let imagePath: String; let outputPath: String; let resolution: Int?; let minFreeMemMB: Int?; let hfCache: String?
    }
    private struct Response: Codable, Sendable { let outputPath: String; let width: Int; let height: Int }
}

public struct ImageUpscaleProvider: CapabilityProvider {
    public typealias UpscaleFn = @Sendable (_ inputPath: String, _ outputPath: String, _ resolution: Int?, _ minFreeMemMB: Int?, _ hfCache: String?) throws -> (width: Int, height: Int)

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
                    let resolution = TextToSVGProvider.intOption(req, "resolution")
                    let minFreeMemMB = TextToSVGProvider.intOption(req, "minFreeMemMB")
                    let hfCache = context.root.cachesURL.appendingPathComponent("image-models", isDirectory: true).path
                    try FileManager.default.createDirectory(at: context.root.tempURL, withIntermediateDirectories: true)
                    let outPath = context.root.tempURL.appendingPathComponent("upscale-\(UUID().uuidString).png").path
                    tempPaths.append(outPath)

                    cont.yield(.status("upscaling image"))
                    let size = try upscale(inPath, outPath, resolution, minFreeMemMB, hfCache)
                    let bytes = try Data(contentsOf: URL(fileURLWithPath: outPath))
                    let artifact = Artifact(
                        kind: .image, mimeType: "image/png", entrypoint: "result.png",
                        metadata: ["width": .int(size.width), "height": .int(size.height)],
                        generatedBy: ArtifactProvenance(providerID: providerID, modelID: req.model, capability: .imageUpscale),
                        validation: .valid, preview: .staticSandbox)
                    let saved = try context.artifactStore.save(artifact, files: ["result.png": bytes])
                    cont.yield(.planResolved(ExecutionPlan.single(
                        capability: req.capability, inputModalities: [.image], outputModality: .image,
                        providerID: providerID, modelID: req.model, backend: .python,
                        rationale: ["Single-provider diffusion super-resolution (mflux SeedVR2)."])))
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
