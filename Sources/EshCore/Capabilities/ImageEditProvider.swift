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
    case qwenEdit = "qwen-edit"     // Qwen-Image-Edit, Apache-2.0 (commercial-safe) — best fidelity, needs >32GB
    case flux2Klein = "flux2-klein" // FLUX.2 Klein 4B, Apache-2.0 (commercial-safe) — the practical fit on 32GB
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

/// All tunables for one image-edit run. Freeform options in the ExecutionRequest map onto this, so adding a
/// knob here does not change the capability contract. `loraPaths`/`loraScales` are resolved local adapter
/// files (generic LoRA — the base model decides compatibility; esh never hard-codes a specific adapter).
public struct ImageEditOptions: Sendable {
    public var backend: ImageEditBackend
    public var model: String?          // explicit weights repo (pin/override), else the backend default
    public var baseModel: String?      // mflux --base-model architecture for a 3rd-party/pre-quantized repo
    public var loraPaths: [String]
    public var loraScales: [Double]
    public var quantize: Int?
    public var seed: Int?
    public var steps: Int?
    public var guidance: Double?
    public var width: Int?
    public var height: Int?
    public var minFreeMemMB: Int?
    public var hfCache: String?
    public init(backend: ImageEditBackend = .flux2Klein, model: String? = nil, baseModel: String? = nil,
                loraPaths: [String] = [], loraScales: [Double] = [], quantize: Int? = nil, seed: Int? = nil,
                steps: Int? = nil, guidance: Double? = nil, width: Int? = nil, height: Int? = nil,
                minFreeMemMB: Int? = nil, hfCache: String? = nil) {
        self.backend = backend; self.model = model; self.baseModel = baseModel
        self.loraPaths = loraPaths; self.loraScales = loraScales; self.quantize = quantize
        self.seed = seed; self.steps = steps; self.guidance = guidance
        self.width = width; self.height = height; self.minFreeMemMB = minFreeMemMB; self.hfCache = hfCache
    }
}

public struct ImageEditService: Sendable {
    private let bridge: MLXBridge
    public init(bridge: MLXBridge = .init()) { self.bridge = bridge }

    /// Edit `imagePath` per `instruction`, writing to `outputPath`. Cancellable + RAM-guarded via the bridge.
    @discardableResult
    public func edit(imagePath: String, outputPath: String, instruction: String,
                     options: ImageEditOptions) throws -> ImageEditResult {
        let r: Response = try bridge.runCancellable(
            command: "image-edit",
            request: Request(imagePath: imagePath, outputPath: outputPath, instruction: instruction,
                             backend: options.backend.rawValue, model: options.model, baseModel: options.baseModel,
                             lora: options.loraPaths.isEmpty ? nil : options.loraPaths,
                             loraScale: options.loraScales.isEmpty ? nil : options.loraScales,
                             quantize: options.quantize, seed: options.seed, steps: options.steps,
                             guidance: options.guidance, width: options.width, height: options.height,
                             minFreeMemMB: options.minFreeMemMB, hfCache: options.hfCache),
            as: Response.self)
        return ImageEditResult(width: r.width, height: r.height, backend: r.backend, model: r.model,
                               license: r.license, commercial: r.commercial)
    }

    /// Install (download) a style adapter's LoRA into the image-models HF cache. Idempotent — returns true
    /// immediately when already present. Small file (hundreds of MB), plain HF download (no RAM guard).
    @discardableResult
    public func installAdapter(id: String, hfCache: String) throws -> Bool {
        guard let adapter = ImageAdapterCatalog.resolve(id) else {
            throw CapabilityError.failed("unknown image adapter '\(id)'")
        }
        if ImageAdapterCatalog.isInstalled(adapter, hfCacheRoot: hfCache) { return true }
        let r: InstallResponse = try bridge.run(
            command: "image-adapter-install",
            request: InstallRequest(sourceRepo: adapter.sourceRepo, file: adapter.file, hfCache: hfCache),
            as: InstallResponse.self)
        return r.installed
    }

    private struct Request: Codable, Sendable {
        let imagePath: String; let outputPath: String; let instruction: String; let backend: String
        let model: String?; let baseModel: String?
        let lora: [String]?; let loraScale: [Double]?
        let quantize: Int?; let seed: Int?; let steps: Int?; let guidance: Double?
        let width: Int?; let height: Int?; let minFreeMemMB: Int?; let hfCache: String?
    }
    private struct Response: Codable, Sendable {
        let outputPath: String; let width: Int; let height: Int
        let backend: String; let model: String; let license: String; let commercial: Bool
    }
    private struct InstallRequest: Codable, Sendable { let sourceRepo: String; let file: String; let hfCache: String }
    private struct InstallResponse: Codable, Sendable { let installed: Bool }
}

public struct ImageEditProvider: CapabilityProvider {
    public typealias EditFn = @Sendable (_ inputPath: String, _ outputPath: String, _ instruction: String,
                                         _ options: ImageEditOptions) throws -> ImageEditResult

    public let descriptor: CapabilityProviderDescriptor
    private let edit: EditFn

    static func doubleOption(_ req: ExecutionRequest, _ key: String) -> Double? {
        switch req.options.values[key] {
        case .double(let v): return v
        case .int(let v): return Double(v)
        case .string(let s): return Double(s)
        default: return nil
        }
    }

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
                    var backend = ImageEditBackend(rawValue: VideoUnderstandingProvider.stringOption(req, "backend") ?? "") ?? .flux2Klein
                    let backendExplicit = VideoUnderstandingProvider.stringOption(req, "backend") != nil
                    let modelPin = VideoUnderstandingProvider.stringOption(req, "model")

                    // Route the model download to the assets root (SSD), never internal disk.
                    let hfCache = context.root.cachesURL.appendingPathComponent("image-models", isDirectory: true).path

                    // Generic adapter (LoRA) resolution. `adapter` (or `lora`) is a NEUTRAL id, e.g.
                    // "3d-animation"; it dictates the compatible base family and carries the recommended base
                    // weights. Base model installs once; adapters install separately (no base duplication).
                    var loraPaths: [String] = []
                    var loraScales: [Double] = []
                    var adapterID: String?
                    var adapterModelRepo: String?
                    var adapterBaseArch: String?
                    if let requested = VideoUnderstandingProvider.stringOption(req, "adapter")
                        ?? VideoUnderstandingProvider.stringOption(req, "lora") {
                        let r = try ImageAdapterCatalog.resolveForEdit(
                            id: requested, scale: Self.doubleOption(req, "adapterScale"),
                            pinnedBackend: backendExplicit ? backend : nil, hfCacheRoot: hfCache)
                        backend = r.backend         // the adapter's base family wins
                        loraPaths = r.loraPaths; loraScales = r.loraScales
                        adapterID = r.adapterID; adapterModelRepo = r.model; adapterBaseArch = r.baseModel
                    }

                    let options = ImageEditOptions(
                        backend: backend,
                        model: modelPin ?? adapterModelRepo,
                        baseModel: adapterBaseArch,
                        loraPaths: loraPaths, loraScales: loraScales,
                        quantize: TextToSVGProvider.intOption(req, "quantize"),
                        seed: TextToSVGProvider.intOption(req, "seed"),
                        steps: TextToSVGProvider.intOption(req, "steps"),
                        guidance: Self.doubleOption(req, "guidance"),
                        width: TextToSVGProvider.intOption(req, "width"),
                        height: TextToSVGProvider.intOption(req, "height"),
                        minFreeMemMB: TextToSVGProvider.intOption(req, "minFreeMemMB"),
                        hfCache: hfCache)

                    try FileManager.default.createDirectory(at: context.root.tempURL, withIntermediateDirectories: true)
                    let outPath = context.root.tempURL.appendingPathComponent("edit-\(UUID().uuidString).png").path
                    tempPaths.append(outPath)

                    // Free RAM held by warm chat/LLM runtimes before spawning the diffusion editor (FLUX.2
                    // Klein ~8.6 GB peak), so the Python RAM guard doesn't refuse the run for low memory on a
                    // 32 GB Mac. The image model isn't in this pool (subprocess CLI) — this only drops idle
                    // LLM/speech, which the edit doesn't need.
                    if let lifecycle = context.lifecycle {
                        // Only reclaim when RAM is actually tight for the diffusion editor (FLUX.2 Klein
                        // ~8.6 GB peak); on a roomy machine the warm chat model is left alone.
                        let evicted = await lifecycle.reclaimForHeavyTask(ifAvailableBelowGB: 14)
                        if !evicted.isEmpty { cont.yield(.status("freed memory for the image model (evicted \(evicted.count) warm model\(evicted.count == 1 ? "" : "s"))")) }
                    }
                    // Preflight: refuse BEFORE loading the diffusion editor if there still isn't enough RAM.
                    // Headroom = measured capped-resolution peak + the bridge's 4 GB run-time guard floor, so a
                    // run that starts won't get killed mid-way (FLUX.2 Klein capped ≈ 12 GB peak → ~16 GB).
                    let neededGB: Double = { switch backend { case .flux2Klein: return 16; case .kontext: return 18; case .qwenEdit: return 30 } }()
                    if let reason = HeavyTaskMemory.insufficientMemoryMessage(neededGB: neededGB, label: "image editing") {
                        throw CapabilityError.failed(reason)
                    }
                    cont.yield(.status("editing image (\(backend.rawValue)\(adapterID.map { " + " + $0 } ?? ""))"))
                    let r = try edit(inPath, outPath, instruction, options)
                    if Task.isCancelled { throw CancellationError() }
                    let bytes = try Data(contentsOf: URL(fileURLWithPath: outPath))
                    // Provenance chain (Phase 11): record the SOURCE artifact this result was edited from (set
                    // by the client on iterative "Edit again"/chained edits), so lineage + Ashex can trace it.
                    let sourceID = VideoUnderstandingProvider.stringOption(req, "sourceArtifactID").flatMap(UUID.init)
                    let provenance = ArtifactProvenance(providerID: providerID, modelID: r.model,
                                                        capability: .imageEdit, sourceArtifactID: sourceID)
                    var metadata: [String: JSONValue] = [
                        "width": .int(r.width), "height": .int(r.height), "backend": .string(r.backend),
                        "model": .string(r.model), "license": .string(r.license), "commercial": .bool(r.commercial),
                        "instruction": .string(instruction)]
                    if let adapterID {   // generic-LoRA provenance: which adapter (neutral id) produced this
                        metadata["adapter"] = .string(adapterID)
                        if let scale = loraScales.first { metadata["adapterScale"] = .double(scale) }
                    }
                    let artifact = Artifact(
                        kind: .image, mimeType: "image/png", entrypoint: "result.png",
                        metadata: metadata,
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
