import Foundation

// esh 2.1 UCMR, Stage 3 — text → image generation. Produces a typed IMAGE artifact from a text prompt
// via mflux's Z-Image Turbo CLI (Apache-2.0, ~8 steps) through the `image-generate` bridge op. mflux is
// an optional dependency; the contract does not depend on the method — a different diffusion backend
// could replace it without contract changes.

/// Thin wrapper over the `image-generate` bridge op (mirrors SegmentationService).
public struct ImageGenerationService: Sendable {
    private let bridge: MLXBridge
    public init(bridge: MLXBridge = .init()) { self.bridge = bridge }

    /// Generate an image for `prompt`, writing a PNG to `outputPath`. Returns its pixel size.
    @discardableResult
    public func generate(prompt: String, outputPath: String, steps: Int, seed: Int,
                         width: Int?, height: Int?, quantize: Int?) throws -> (width: Int, height: Int) {
        let response: Response = try bridge.run(
            command: "image-generate",
            request: Request(prompt: prompt, outputPath: outputPath, steps: steps, seed: seed,
                             width: width, height: height, quantize: quantize),
            as: Response.self)
        return (response.width, response.height)
    }

    private struct Request: Codable, Sendable {
        let prompt: String; let outputPath: String; let steps: Int; let seed: Int
        let width: Int?; let height: Int?; let quantize: Int?
    }
    private struct Response: Codable, Sendable { let outputPath: String; let width: Int; let height: Int }
}

public struct ImageGenerationProvider: CapabilityProvider {
    public typealias GenerateFn = @Sendable (_ prompt: String, _ outputPath: String, _ steps: Int, _ seed: Int,
                                             _ width: Int?, _ height: Int?, _ quantize: Int?) throws -> (width: Int, height: Int)

    public let descriptor: CapabilityProviderDescriptor
    private let generate: GenerateFn

    public init(id: String = "image-generation", generate: @escaping GenerateFn) {
        self.descriptor = CapabilityProviderDescriptor(
            id: id,
            capabilities: [.imageGenerate],
            acceptedInputs: [.text],
            producedOutputs: [.image],
            backend: .python,
            streaming: false,
            structuredOutput: false,
            requiredPrivilege: .artifactOnly,
            previewMode: .staticSandbox)
        self.generate = generate
    }

    public func execute(_ request: ResolvedExecutionRequest, context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        let req = request.request
        let generate = self.generate
        let providerID = descriptor.id
        return AsyncThrowingStream { cont in
            let task = Task {
                var tempPaths: [String] = []
                defer { for p in tempPaths { try? FileManager.default.removeItem(atPath: p) } }
                do {
                    let prompt = req.inputs.compactMap { input -> String? in
                        if case .text(let t) = input.payload { return t }
                        return nil
                    }.joined(separator: "\n")
                    guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw CapabilityError.failed("image generation requires a text prompt")
                    }
                    let steps = TextToSVGProvider.intOption(req, "steps") ?? 8
                    let seed = TextToSVGProvider.intOption(req, "seed") ?? 0
                    let width = TextToSVGProvider.intOption(req, "width")
                    let height = TextToSVGProvider.intOption(req, "height")
                    let quantize = TextToSVGProvider.intOption(req, "quantize")

                    try FileManager.default.createDirectory(at: context.root.tempURL, withIntermediateDirectories: true)
                    let outPath = context.root.tempURL.appendingPathComponent("gen-\(UUID().uuidString).png").path
                    tempPaths.append(outPath)

                    cont.yield(.status("generating image"))
                    let size = try generate(prompt, outPath, steps, seed, width, height, quantize)
                    let bytes = try Data(contentsOf: URL(fileURLWithPath: outPath))
                    let artifact = Artifact(
                        kind: .image, mimeType: "image/png", entrypoint: "result.png",
                        metadata: ["width": .int(size.width), "height": .int(size.height), "steps": .int(steps)],
                        generatedBy: ArtifactProvenance(providerID: providerID, modelID: req.model, capability: .imageGenerate),
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
