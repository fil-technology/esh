import Foundation

// esh 2.1 UCMR — instruction-based image editing (image + instruction → image). A first-class capability
// behind the Universal Capability Runtime, NOT a frontend trick. One coherent `image.edit` provider whose
// OPERATION rides in the natural-language instruction (+ optional mask later), rather than a fan-out of
// image.inpaint/outpaint/restyle/… — the router reasons in user intent, not model names.
//
// Backends (mflux, MLX-native — best Apple-Silicon path):
//  • DEFAULT `qwen-edit` — Qwen-Image-Edit (Apache-2.0, commercial-safe), strong instruction fidelity + identity.
//  • EXPERIMENTAL `kontext` — FLUX.1 Kontext [dev] (NON-COMMERCIAL / BFL license) — best iterative stability,
//    lighter; opt-in only, never the commercial default. Licence is surfaced in the artifact provenance.
// RAM-guarded + killable (cancellation reclaims the subprocess). Model downloads on first use to the SSD.

public enum ImageEditBackend: String, Sendable, CaseIterable {
    case qwenEdit = "qwen-edit"     // default: Qwen-Image-Edit, Apache-2.0 (commercial-safe)
    case kontext = "kontext"        // experimental: FLUX.1 Kontext [dev], non-commercial license
}

public struct ImageEditResult: Sendable {
    public let width: Int, height: Int
    public let backend: String, model: String, license: String, commercial: Bool
    public init(width: Int, height: Int, backend: String, model: String, license: String, commercial: Bool) {
        self.width = width; self.height = height; self.backend = backend
        self.model = model; self.license = license; self.commercial = commercial
    }
}

public struct ImageEditService: Sendable {
    private let bridge: MLXBridge
    public init(bridge: MLXBridge = .init()) { self.bridge = bridge }

    /// Edit `imagePath` per `instruction`, writing to `outputPath`. Cancellable + RAM-guarded via the bridge.
    @discardableResult
    public func edit(imagePath: String, outputPath: String, instruction: String, backend: ImageEditBackend,
                     quantize: Int?, minFreeMemMB: Int?, hfCache: String?) throws -> ImageEditResult {
        let r: Response = try bridge.runCancellable(
            command: "image-edit",
            request: Request(imagePath: imagePath, outputPath: outputPath, instruction: instruction,
                             backend: backend.rawValue, quantize: quantize, minFreeMemMB: minFreeMemMB, hfCache: hfCache),
            as: Response.self)
        return ImageEditResult(width: r.width, height: r.height, backend: r.backend, model: r.model,
                               license: r.license, commercial: r.commercial)
    }

    private struct Request: Codable, Sendable {
        let imagePath: String; let outputPath: String; let instruction: String; let backend: String
        let quantize: Int?; let minFreeMemMB: Int?; let hfCache: String?
    }
    private struct Response: Codable, Sendable {
        let outputPath: String; let width: Int; let height: Int
        let backend: String; let model: String; let license: String; let commercial: Bool
    }
}

public struct ImageEditProvider: CapabilityProvider {
    public typealias EditFn = @Sendable (_ inputPath: String, _ outputPath: String, _ instruction: String,
                                         _ backend: ImageEditBackend, _ minFreeMemMB: Int?, _ hfCache: String?) throws -> ImageEditResult

    public let descriptor: CapabilityProviderDescriptor
    private let edit: EditFn

    public init(id: String = "image-edit", edit: @escaping EditFn) {
        self.descriptor = CapabilityProviderDescriptor(
            id: id,
            capabilities: [.imageEdit],
            acceptedInputs: [.image, .text],
            producedOutputs: [.image],
            backend: .python,
            streaming: false,
            structuredOutput: false,
            requiredPrivilege: .artifactOnly,
            previewMode: .staticSandbox)
        self.edit = edit
    }

    public func execute(_ request: ResolvedExecutionRequest, context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        let req = request.request
        let edit = self.edit
        let providerID = descriptor.id
        return AsyncThrowingStream { cont in
            let task = Task {
                var tempPaths: [String] = []
                defer { for p in tempPaths { try? FileManager.default.removeItem(atPath: p) } }
                do {
                    // Inputs: an image + a text instruction ("Change the sky to sunset.").
                    guard let image = req.inputs.compactMap({ input -> EshAttachment? in
                        if case .attachment(let a) = input.payload, a.kind == .image { return a }
                        return nil
                    }).first else {
                        throw CapabilityError.failed("image editing requires an image input")
                    }
                    let instruction = req.inputs.compactMap { input -> String? in
                        if case .text(let t) = input.payload { return t }
                        return nil
                    }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !instruction.isEmpty else {
                        throw CapabilityError.failed("image editing requires an instruction (e.g. \"change the sky to sunset\")")
                    }

                    try StorageService().ensureAssetsAvailable(root: context.root)   // never fill internal disk
                    let (inPath, isTemp) = try VisionUnderstandProvider.materialize(image, root: context.root)
                    if isTemp { tempPaths.append(inPath) }
                    let backend = ImageEditBackend(rawValue: VideoUnderstandingProvider.stringOption(req, "backend") ?? "") ?? .qwenEdit
                    let minFreeMemMB = TextToSVGProvider.intOption(req, "minFreeMemMB")
                    try FileManager.default.createDirectory(at: context.root.tempURL, withIntermediateDirectories: true)
                    let outPath = context.root.tempURL.appendingPathComponent("edit-\(UUID().uuidString).png").path
                    tempPaths.append(outPath)

                    // Route the model download to the assets root (SSD), never internal disk.
                    let hfCache = context.root.cachesURL.appendingPathComponent("image-models", isDirectory: true).path
                    cont.yield(.status("editing image (\(backend.rawValue))"))
                    let r = try edit(inPath, outPath, instruction, backend, minFreeMemMB, hfCache)
                    if Task.isCancelled { throw CancellationError() }
                    let bytes = try Data(contentsOf: URL(fileURLWithPath: outPath))
                    // Provenance chain (Phase 11): record the SOURCE artifact this result was edited from (set
                    // by the client on iterative "Edit again"/chained edits), so lineage + Ashex can trace it.
                    let sourceID = VideoUnderstandingProvider.stringOption(req, "sourceArtifactID").flatMap(UUID.init)
                    let provenance = ArtifactProvenance(providerID: providerID, modelID: r.model,
                                                        capability: .imageEdit, sourceArtifactID: sourceID)
                    let artifact = Artifact(
                        kind: .image, mimeType: "image/png", entrypoint: "result.png",
                        metadata: ["width": .int(r.width), "height": .int(r.height), "backend": .string(r.backend),
                                   "model": .string(r.model), "license": .string(r.license), "commercial": .bool(r.commercial),
                                   "instruction": .string(instruction)],
                        generatedBy: provenance, validation: .valid, preview: .staticSandbox)
                    let saved = try context.artifactStore.save(artifact, files: ["result.png": bytes])
                    cont.yield(.planResolved(ExecutionPlan.single(
                        capability: req.capability, inputModalities: [.image, .text], outputModality: .image,
                        providerID: providerID, modelID: r.model, backend: .python,
                        rationale: ["Instruction-based image editing (\(r.backend), \(r.model)) — license: \(r.license)\(r.commercial ? "" : " (non-commercial)").",
                                    "Operation carried by the instruction: \"\(instruction.prefix(80))\"."])))
                    cont.yield(.artifactProduced(saved))
                    cont.yield(.done(finishReason: "stop"))
                    cont.finish()
                } catch is CancellationError {
                    cont.yield(.failed(message: "image editing was cancelled"))
                    cont.finish(throwing: CancellationError())
                } catch {
                    cont.yield(.failed(message: error.localizedDescription))
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}
