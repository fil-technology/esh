import Foundation

// esh 2.1 UCMR, Stage 1 — text→SVG CapabilityProvider. Prompts an installed LLM for a constrained JSON
// scene IR, compiles it deterministically to safe SVG, validates, and persists a typed SVG Artifact
// (preview: static-sandbox). The capability contract does not depend on this method — a specialized
// vector model or an image→vector provider could replace it without contract changes.

public struct TextToSVGProvider: CapabilityProvider {
    public typealias InferFn = @Sendable (ExternalInferenceRequest) async throws -> ExternalInferenceResponse
    /// A "strong" JSON-reliable text backend (e.g. Apple Intelligence on-device), given (system, user,
    /// maxTokens) → (rawText, modelLabel). nil when no such backend is available on this Mac.
    public typealias StrongInferFn = @Sendable (_ system: String, _ user: String, _ maxTokens: Int) async throws -> (text: String, model: String)

    public let descriptor: CapabilityProviderDescriptor
    private let infer: InferFn
    private let strongInfer: StrongInferFn?
    /// True when Auto should try the strong backend FIRST (quality-first, still on-device). Read at call
    /// time so a user who pins a specific model for vector.generate gets THAT model first instead.
    private let preferStrongFirst: @Sendable () -> Bool

    public init(id: String = "text-to-svg", infer: @escaping InferFn,
                strongInfer: StrongInferFn? = nil,
                preferStrongFirst: @escaping @Sendable () -> Bool = { false }) {
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
        self.strongInfer = strongInfer
        self.preferStrongFirst = preferStrongFirst
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
        let strongInfer = self.strongInfer
        let preferStrongFirst = self.preferStrongFirst
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
                    let system = Self.systemInstruction + "\nCanvas: \(width)x\(height)."
                    let userPrompt = prompt.isEmpty ? "a simple abstract illustration" : prompt

                    // The local model bound to req.model (Auto-resolved or user-pinned).
                    let localAttempt: SVGAttempt = { sys, user, maxT in
                        let response = try await infer(ExternalInferenceRequest(
                            model: req.model,
                            messages: [ExternalInferenceMessage(role: .system, text: sys),
                                       ExternalInferenceMessage(role: .user, text: user)],
                            generation: GenerationConfig(maxTokens: maxT, temperature: 0.4),
                            responseFormat: .json))
                        let raw = ThinkingParser.parse(response.outputText).answer ?? response.outputText
                        return (raw, response.modelID)
                    }
                    // Order the attempts: quality-first (strong backend) for Auto, else the user's pinned
                    // local model first. Each attempt still falls through to the other on failure.
                    var attempts: [SVGAttempt] = []
                    if preferStrongFirst(), let s = strongInfer {
                        attempts = [{ sys, user, maxT in try await s(sys, user, maxT) }, localAttempt]
                    } else {
                        attempts = [localAttempt]
                        if let s = strongInfer { attempts.append({ sys, user, maxT in try await s(sys, user, maxT) }) }
                    }

                    // Try each backend up to twice (initial + one repair pass on non-JSON output) before
                    // moving to the next. This turns a small model's occasional bad JSON into a retry, and
                    // a persistent failure into a clean escalation — instead of a dead end.
                    var scene: SVGScene?
                    var usedModel = req.model ?? "unknown"
                    var lastError: Error?
                    outer: for (i, attempt) in attempts.enumerated() {
                        if i > 0 { cont.yield(.status("retrying with a more reliable model")) }
                        var user = userPrompt
                        for pass in 0..<2 {
                            if Task.isCancelled { throw CancellationError() }
                            do {
                                let (raw, model) = try await attempt(system, user, maxTokens)
                                if let json = Self.extractJSONObject(raw),
                                   var decoded = try? JSONDecoder().decode(SVGScene.self, from: Data(json.utf8)) {
                                    if decoded.width <= 0 { decoded.width = width }
                                    if decoded.height <= 0 { decoded.height = height }
                                    scene = decoded; usedModel = model
                                    break outer
                                }
                                // Non-JSON / undecodable → one repair pass feeding the bad output back.
                                if pass == 0 {
                                    user = userPrompt + "\n\nYour previous reply was NOT valid JSON. Reply again "
                                        + "with ONLY the JSON object described above — no prose, no markdown fences. "
                                        + "Previous reply:\n" + String(raw.prefix(400))
                                }
                            } catch {
                                lastError = error
                                break   // hard backend error → skip to the next attempt
                            }
                        }
                    }

                    guard let scene else {
                        // Every backend and repair failed. Keep the honest message; the UI collapses it.
                        throw lastError ?? CapabilityError.failed("The model did not return a valid JSON scene.")
                    }

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
                        generatedBy: ArtifactProvenance(providerID: providerID, modelID: usedModel, capability: .vectorGenerate),
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

    /// One vector-scene generation attempt against a backend: (system, user, maxTokens) → (rawText, model).
    typealias SVGAttempt = @Sendable (_ system: String, _ user: String, _ maxTokens: Int) async throws -> (String, String)

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
