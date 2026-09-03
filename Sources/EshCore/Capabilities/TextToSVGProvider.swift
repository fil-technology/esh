import Foundation

// esh 2.1 UCMR, Stage 1 — text→SVG CapabilityProvider. Prompts an installed LLM for a constrained JSON
// scene IR, compiles it deterministically to safe SVG, validates, and persists a typed SVG Artifact
// (preview: static-sandbox). The capability contract does not depend on this method — a specialized
// vector model or an image→vector provider could replace it without contract changes.

public struct TextToSVGProvider: CapabilityProvider {
    public typealias InferFn = @Sendable (ExternalInferenceRequest) async throws -> ExternalInferenceResponse

    public let descriptor: CapabilityProviderDescriptor
    private let infer: InferFn

    public init(id: String = "text-to-svg", infer: @escaping InferFn) {
        self.descriptor = CapabilityProviderDescriptor(
            id: id,
            capabilities: [.vectorGenerate],
            acceptedInputs: [.text],
            producedOutputs: [.image],
            backend: .native,
            modelFamily: nil,
            streaming: false,
            structuredOutput: true,
            requiredPrivilege: .artifactOnly,
            previewMode: .staticSandbox)
        self.infer = infer
    }

    static let systemInstruction = """
    You convert a description into a small JSON vector scene. Respond with ONLY a JSON object (no prose, \
    no markdown fences) of this shape:
    {"width":Int,"height":Int,"background":"#hex-or-color-or-null","elements":[ ... ]}
    Each element is an object with a "type" of one of: rect, circle, ellipse, line, polyline, polygon, \
    path, text. Use only these fields as appropriate: x,y,width,height,rx,ry,cx,cy,r,x1,y1,x2,y2,points \
    ("x1,y1 x2,y2 ..."),d (SVG path data),text,fontSize,fontFamily,textAnchor,fill,stroke,strokeWidth, \
    opacity,transform. Colors must be hex (#rgb/#rrggbb), a CSS color name, rgb()/rgba(), or "none". \
    Do NOT include script, images, external links, or event handlers. Keep coordinates within the canvas.
    """

    public func execute(_ request: ResolvedExecutionRequest,
                        context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        let req = request.request
        let infer = self.infer
        let providerID = descriptor.id
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    cont.yield(.status("composing vector scene"))
                    let prompt = req.inputs.compactMap { input -> String? in
                        if case .text(let t) = input.payload { return t }
                        return nil
                    }.joined(separator: "\n")

                    let width = Self.intOption(req, "width") ?? 512
                    let height = Self.intOption(req, "height") ?? 512
                    let maxTokens = Self.intOption(req, "maxTokens") ?? 1500

                    let messages = [
                        ExternalInferenceMessage(role: .system, text: Self.systemInstruction + "\nCanvas: \(width)x\(height)."),
                        ExternalInferenceMessage(role: .user, text: prompt.isEmpty ? "a simple abstract illustration" : prompt)
                    ]
                    let inferReq = ExternalInferenceRequest(
                        model: req.model,
                        messages: messages,
                        generation: GenerationConfig(maxTokens: maxTokens, temperature: 0.4),
                        responseFormat: .json)

                    let response = try await infer(inferReq)
                    let raw = ThinkingParser.parse(response.outputText).answer ?? response.outputText
                    guard let json = Self.extractJSONObject(raw) else {
                        throw CapabilityError.failed("The model did not return a JSON scene.")
                    }
                    var scene = try JSONDecoder().decode(SVGScene.self, from: Data(json.utf8))
                    // Default the canvas to the requested size when the model omitted it.
                    if scene.width <= 0 { scene.width = width }
                    if scene.height <= 0 { scene.height = height }

                    cont.yield(.status("rendering svg"))
                    let svg = SVGSceneRenderer.render(scene)
                    let validation = SVGValidator.validate(svg, expectedWidth: scene.width, expectedHeight: scene.height)

                    let artifact = Artifact(
                        kind: .svg,
                        mimeType: "image/svg+xml",
                        entrypoint: "scene.svg",
                        metadata: [
                            "width": .int(scene.width),
                            "height": .int(scene.height),
                            "elementCount": .int(scene.elements.count)
                        ],
                        generatedBy: ArtifactProvenance(providerID: providerID, modelID: response.modelID, capability: .vectorGenerate),
                        validation: validation,
                        preview: .staticSandbox)
                    let saved = try context.artifactStore.save(artifact, files: ["scene.svg": Data(svg.utf8)])
                    cont.yield(.artifactProduced(saved))
                    cont.yield(.done(finishReason: validation.isValid ? "stop" : "invalid"))
                    cont.finish()
                } catch {
                    cont.yield(.failed(message: error.localizedDescription))
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    static func intOption(_ req: ExecutionRequest, _ key: String) -> Int? {
        switch req.options.values[key] {
        case .int(let v): return v
        case .double(let v): return Int(v)
        default: return nil
        }
    }

    /// Extract the outermost JSON object from a possibly-wrapped model response.
    static func extractJSONObject(_ s: String) -> String? {
        guard let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}"), start < end else { return nil }
        return String(s[start...end])
    }
}
