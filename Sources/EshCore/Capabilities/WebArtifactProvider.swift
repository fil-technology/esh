import Foundation

// esh 2.1 UCMR — webArtifact.generate: text → a single SELF-CONTAINED HTML page (inline CSS + JS, no external
// network). A first ProjectArtifact primitive: esh produces runnable web output, not just model text. The
// LLM emits the HTML; esh validates it (self-contained, well-formed) and persists a typed `.webProject`
// artifact rendered in an ISOLATED sandbox (sandboxed iframe: scripts run but cannot touch the parent,
// cookies, storage, or the network). The contract doesn't depend on the model — a stronger coder model or a
// template engine could replace the method without contract changes.
//
// Boundary: esh GENERATES the artifact (typed, validated, previewable). Autonomously deploying/editing the
// user's real project belongs to Ashex — not here.

/// Validates a generated HTML page: it must be non-trivial and SELF-CONTAINED (the contract). External
/// resources (CDN scripts, remote stylesheets/images, network fetches) are flagged as findings — the page
/// still previews (sandboxed), but the self-contained guarantee is reported honestly.
public enum WebArtifactValidator {
    public static func validate(_ html: String) -> ArtifactValidation {
        let lower = html.lowercased()
        var findings: [String] = []
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 30, lower.contains("<") , lower.contains(">") else {
            return ArtifactValidation(isValid: false, findings: ["output is not HTML"])
        }
        if !lower.contains("<html") && !lower.contains("<!doctype") && !lower.contains("<body") && !lower.contains("<div") {
            findings.append("no obvious HTML structure (fragment)")
        }
        // Self-contained checks — external references break the "no network" guarantee.
        for pat in ["src=\"http", "src='http", "href=\"http", "href='http", "@import url(http", "url(http"] {
            if lower.contains(pat) { findings.append("references an external resource (\(pat)) — not fully self-contained"); break }
        }
        for pat in ["fetch(", "xmlhttprequest", "import(", "importscripts("] {
            if lower.contains(pat) { findings.append("performs a network/dynamic request (\(pat)) — blocked by the sandbox"); break }
        }
        // isValid = it IS usable HTML; findings note the self-contained caveats (sandbox enforces isolation).
        return ArtifactValidation(isValid: true, findings: findings)
    }
}

public struct WebArtifactProvider: CapabilityProvider {
    public typealias InferFn = @Sendable (ExternalInferenceRequest) async throws -> ExternalInferenceResponse
    public typealias StrongInferFn = @Sendable (_ system: String, _ user: String, _ maxTokens: Int) async throws -> (text: String, model: String)
    typealias Attempt = @Sendable (_ system: String, _ user: String, _ maxTokens: Int) async throws -> (String, String)

    public let descriptor: CapabilityProviderDescriptor
    private let infer: InferFn
    private let strongInfer: StrongInferFn?
    private let preferStrongFirst: @Sendable () -> Bool

    public init(id: String = "text-to-webartifact", infer: @escaping InferFn,
                strongInfer: StrongInferFn? = nil,
                preferStrongFirst: @escaping @Sendable () -> Bool = { false }) {
        self.descriptor = CapabilityProviderDescriptor(
            id: id,
            capabilities: [.webArtifactGenerate],
            acceptedInputs: [.text],
            producedOutputs: [.text],
            backend: .native,
            modelFamily: nil,
            streaming: false,
            structuredOutput: false,
            requiredPrivilege: .previewSandboxed,
            previewMode: .staticSandbox)
        self.infer = infer
        self.strongInfer = strongInfer
        self.preferStrongFirst = preferStrongFirst
    }

    static let systemInstruction = """
    You are a web page generator. Produce ONE complete, self-contained HTML5 document that fulfils the user's \
    request. Requirements: start with <!DOCTYPE html>; put ALL CSS in a <style> tag and ALL JavaScript in a \
    <script> tag INLINE; do NOT reference any external resource — no CDNs, no remote scripts, stylesheets, \
    fonts, or images, no fetch/XHR/network. Use only inline SVG or data: URIs for graphics. Make it work \
    offline in a sandboxed iframe. Reply with ONLY the HTML — no markdown fences, no prose, no explanation.
    """

    static let reviseInstruction = """
    You revise an existing HTML page. Apply ONLY the requested change while preserving everything else (layout, \
    content, styles) as much as possible. Keep it a single self-contained HTML5 document — all CSS/JS inline, \
    NO external resources or network. Reply with ONLY the complete updated HTML — no markdown fences, no prose.
    """

    public func execute(_ request: ResolvedExecutionRequest, context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        let req = request.request
        let infer = self.infer
        let strongInfer = self.strongInfer
        let preferStrongFirst = self.preferStrongFirst
        let providerID = descriptor.id
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    cont.yield(.status("composing web page"))
                    let prompt = req.inputs.compactMap { input -> String? in
                        if case .text(let t) = input.payload { return t }
                        return nil
                    }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    let maxTokens = TextToSVGProvider.intOption(req, "maxTokens") ?? 4000

                    // Iterative editing: if a prior web artifact is referenced (sourceArtifactID), load its HTML
                    // and REVISE it per the instruction — the operation rides in the instruction, with lineage.
                    let sourceID = VideoUnderstandingProvider.stringOption(req, "sourceArtifactID").flatMap(UUID.init)
                    var currentHTML: String? = nil
                    if let sourceID, let a = try? context.artifactStore.load(id: sourceID),
                       let data = try? context.artifactStore.data(id: sourceID, file: a.entrypoint ?? "index.html") {
                        currentHTML = String(decoding: data, as: UTF8.self)
                        cont.yield(.status("revising web page"))
                    }
                    let system: String
                    let userPrompt: String
                    if let cur = currentHTML {
                        system = Self.reviseInstruction
                        userPrompt = "Apply this change: \(prompt.isEmpty ? "improve the page" : prompt)\n\nCurrent HTML:\n\(cur)"
                    } else {
                        system = Self.systemInstruction
                        userPrompt = prompt.isEmpty ? "a simple hello-world page" : prompt
                    }

                    let localAttempt: Attempt = { sys, user, maxT in
                        let response = try await infer(ExternalInferenceRequest(
                            model: req.model,
                            messages: [ExternalInferenceMessage(role: .system, text: sys),
                                       ExternalInferenceMessage(role: .user, text: user)],
                            generation: GenerationConfig(maxTokens: maxT, temperature: 0.4)))
                        return (ThinkingParser.parse(response.outputText).answer ?? response.outputText, response.modelID)
                    }
                    // Quality-first for Auto (strong coder/Apple FM first), else the pinned/resident model first.
                    var attempts: [Attempt] = []
                    if preferStrongFirst(), let s = strongInfer {
                        attempts = [{ sys, user, maxT in try await s(sys, user, maxT) }, localAttempt]
                    } else {
                        attempts = [localAttempt]
                        if let s = strongInfer { attempts.append({ sys, user, maxT in try await s(sys, user, maxT) }) }
                    }

                    var html: String?
                    var usedModel = req.model ?? "unknown"
                    var lastError: Error?
                    outer: for (i, attempt) in attempts.enumerated() {
                        if i > 0 { cont.yield(.status("retrying with a more reliable model")) }
                        var user = userPrompt
                        for pass in 0..<2 {
                            if Task.isCancelled { throw CancellationError() }
                            do {
                                let (raw, model) = try await attempt(system, user, maxTokens)
                                let extracted = Self.extractHTML(raw)
                                if WebArtifactValidator.validate(extracted).isValid {
                                    html = extracted; usedModel = model; break outer
                                }
                                if pass == 0 {
                                    user = userPrompt + "\n\nYour previous reply was not a valid self-contained HTML "
                                        + "document. Reply again with ONLY the HTML, starting with <!DOCTYPE html>, "
                                        + "all CSS/JS inline, no external resources."
                                }
                            } catch { lastError = error; break }
                        }
                    }
                    guard let html else {
                        throw lastError ?? CapabilityError.failed("The model did not produce a valid HTML page.")
                    }

                    cont.yield(.status("validating"))
                    let validation = WebArtifactValidator.validate(html)
                    let artifact = Artifact(
                        kind: .webProject, mimeType: "text/html", entrypoint: "index.html",
                        metadata: ["byteSize": .int(html.utf8.count), "selfContained": .bool(validation.findings.isEmpty),
                                   "revised": .bool(currentHTML != nil)],
                        generatedBy: ArtifactProvenance(providerID: providerID, modelID: usedModel,
                                                        capability: .webArtifactGenerate, sourceArtifactID: sourceID),
                        validation: validation, preview: .staticSandbox)
                    let saved = try context.artifactStore.save(artifact, files: ["index.html": Data(html.utf8)])
                    cont.yield(.planResolved(ExecutionPlan.single(
                        capability: req.capability, inputModalities: [.text], outputModality: .text,
                        providerID: providerID, modelID: usedModel, backend: .native,
                        rationale: ["Generated a self-contained HTML page (\(usedModel)) — previewed in an isolated sandbox.",
                                    validation.findings.isEmpty ? "Self-contained: no external resources." : "Note: \(validation.findings.joined(separator: "; "))."])))
                    cont.yield(.artifactProduced(saved))
                    cont.yield(.done(finishReason: validation.isValid ? "stop" : "invalid"))
                    cont.finish()
                } catch is CancellationError {
                    cont.yield(.failed(message: "web page generation was cancelled"))
                    cont.finish(throwing: CancellationError())
                } catch {
                    cont.yield(.failed(message: error.localizedDescription))
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// Strip markdown fences / prose and return the HTML from the model's reply (from the first <!doctype/<html
    /// or first tag to the last closing tag). Defensive: models sometimes wrap HTML in ```html fences.
    static func extractHTML(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Prefer a fenced ```html … ``` block if present.
        if let fenceStart = s.range(of: "```") {
            let afterFence = s[fenceStart.upperBound...]
            // Drop an optional language tag on the same line.
            let body = afterFence.drop(while: { $0 != "\n" }).dropFirst()
            if let fenceEnd = body.range(of: "```") { s = String(body[..<fenceEnd.lowerBound]) }
            else { s = String(body) }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Trim to the HTML span if there's leading/trailing prose.
        let lower = s.lowercased()
        if let dt = lower.range(of: "<!doctype") { s = String(s[dt.lowerBound...]) }
        else if let h = lower.range(of: "<html") { s = String(s[h.lowerBound...]) }
        if let end = s.range(of: "</html>", options: .backwards) { s = String(s[..<end.upperBound]) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
