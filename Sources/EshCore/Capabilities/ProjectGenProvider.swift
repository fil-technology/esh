import Foundation

// esh 2.1 UCMR — project.generate: text → a small MULTI-FILE static web project (index.html + style.css +
// script.js …) as a typed `.webProject` ProjectArtifact, previewed in the SAME isolated sandbox (the entry
// loads siblings by relative path from the artifact store). Pure LLM codegen — no npm, no build, no
// dev-server (running untrusted generated Node code + a managed runtime is a separate, heavier tier, NOT
// this). Files are validated: safe relative paths, self-contained (no external network), index.html present.

/// One generated project file (from the model's JSON manifest).
struct ProjectFile: Codable, Sendable { let path: String; let content: String }
struct ProjectManifest: Codable, Sendable { let files: [ProjectFile] }

public enum ProjectValidator {
    /// True when a file's content is a placeholder/ellipsis rather than real code — some models emit "…" or
    /// "// ..." instead of writing the file. We reject these so the provider retries / escalates.
    static func isPlaceholder(_ content: String) -> Bool {
        let t = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        // Only dots / ellipsis / comment-ellipsis, or too short to be a real file.
        let stripped = t.replacingOccurrences(of: "…", with: ".")
            .trimmingCharacters(in: CharacterSet(charactersIn: "./ \t\r\n<!->/*"))
        return stripped.isEmpty
    }

    /// Returns (safeFiles, validation). Drops unsafe paths; flags external resources. index.html required and
    /// must be real HTML (not a placeholder) for the project to be valid.
    public static func validate(_ files: [(path: String, content: String)]) -> (files: [(path: String, content: String)], validation: ArtifactValidation) {
        var findings: [String] = []
        var safe: [(String, String)] = []
        for f in files {
            let p = f.path.trimmingCharacters(in: .whitespaces)
            // Reject traversal / absolute / empty paths — everything stays inside the artifact bundle.
            if p.isEmpty || p.hasPrefix("/") || p.contains("..") || p.hasPrefix("~") {
                findings.append("dropped unsafe path: \(f.path)"); continue
            }
            if isPlaceholder(f.content) {
                findings.append("\(p): placeholder/empty content — dropped"); continue
            }
            if f.content.lowercased().range(of: #"(src|href)\s*=\s*["']https?:"#, options: .regularExpression) != nil {
                findings.append("\(p): references an external resource — not fully self-contained")
            }
            safe.append((p, f.content))
        }
        let index = safe.first { $0.0.lowercased() == "index.html" }
        if index == nil { findings.append("no index.html entrypoint with real content") }
        // The entrypoint must look like an actual HTML document, not a fragment/placeholder.
        var indexLooksReal = false
        if let index {
            let lower = index.1.lowercased()
            indexLooksReal = index.1.count >= 30 && lower.contains("<") && lower.contains(">")
            if !indexLooksReal { findings.append("index.html is not a usable HTML document") }
        }
        let isValid = index != nil && indexLooksReal && !safe.isEmpty
        return (safe, ArtifactValidation(isValid: isValid, findings: findings))
    }
}

public struct ProjectGenProvider: CapabilityProvider {
    public typealias InferFn = @Sendable (ExternalInferenceRequest) async throws -> ExternalInferenceResponse
    public typealias StrongInferFn = @Sendable (_ system: String, _ user: String, _ maxTokens: Int) async throws -> (text: String, model: String)
    typealias Attempt = @Sendable (_ system: String, _ user: String, _ maxTokens: Int) async throws -> (String, String)

    public let descriptor: CapabilityProviderDescriptor
    private let infer: InferFn
    private let strongInfer: StrongInferFn?
    private let preferStrongFirst: @Sendable () -> Bool

    public init(id: String = "project-generate", infer: @escaping InferFn,
                strongInfer: StrongInferFn? = nil, preferStrongFirst: @escaping @Sendable () -> Bool = { false }) {
        self.descriptor = CapabilityProviderDescriptor(
            id: id, capabilities: [.projectGenerate], acceptedInputs: [.text], producedOutputs: [.text],
            backend: .native, modelFamily: nil, streaming: false, structuredOutput: true,
            requiredPrivilege: .previewSandboxed, previewMode: .staticSandbox)
        self.infer = infer; self.strongInfer = strongInfer; self.preferStrongFirst = preferStrongFirst
    }

    static let systemInstruction = """
    You generate a SMALL multi-file static web project. Respond with ONLY a JSON object of this shape: \
    {"files":[{"path":"index.html","content":"..."},{"path":"style.css","content":"..."},{"path":"script.js","content":"..."}]}. \
    Rules: include an index.html entrypoint that references the other files by RELATIVE path (e.g. \
    <link rel="stylesheet" href="style.css">, <script src="script.js"></script>); keep it fully \
    self-contained — NO external CDNs/URLs/fonts/network; paths must be simple relative names (no "/" prefix, \
    no ".."). No markdown fences, no prose — ONLY the JSON.
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
                    cont.yield(.status("composing project"))
                    let prompt = req.inputs.compactMap { input -> String? in
                        if case .text(let t) = input.payload { return t }; return nil
                    }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    let userPrompt = prompt.isEmpty ? "a small static website" : prompt
                    let maxTokens = TextToSVGProvider.intOption(req, "maxTokens") ?? 4000

                    let localAttempt: Attempt = { sys, user, maxT in
                        let response = try await infer(ExternalInferenceRequest(
                            model: req.model,
                            messages: [ExternalInferenceMessage(role: .system, text: sys),
                                       ExternalInferenceMessage(role: .user, text: user)],
                            generation: GenerationConfig(maxTokens: maxT, temperature: 0.4), responseFormat: .json))
                        return (ThinkingParser.parse(response.outputText).answer ?? response.outputText, response.modelID)
                    }
                    // Apple FM has a small (~4K) context window: reserving the full output budget overflows it
                    // (input + reserved output > window). Clamp the strong attempt so a small 3-file project
                    // still fits comfortably; the local model keeps the larger budget.
                    var strongAttempt: Attempt? = nil
                    if let s = strongInfer {
                        strongAttempt = { sys, user, maxT in try await s(sys, user, min(maxT, 3000)) }
                    }
                    var attempts: [Attempt] = []
                    if preferStrongFirst(), let strongAttempt {
                        attempts = [strongAttempt, localAttempt]
                    } else {
                        attempts = [localAttempt]
                        if let strongAttempt { attempts.append(strongAttempt) }
                    }

                    var files: [(path: String, content: String)]?
                    var validation = ArtifactValidation.notValidated
                    var usedModel = req.model ?? "unknown"
                    var lastError: Error?
                    outer: for (i, attempt) in attempts.enumerated() {
                        if i > 0 { cont.yield(.status("retrying with a more reliable model")) }
                        var user = userPrompt
                        for pass in 0..<2 {
                            if Task.isCancelled { throw CancellationError() }
                            do {
                                let (raw, model) = try await attempt(Self.systemInstruction, user, maxTokens)
                                if let json = TextToSVGProvider.extractJSONObject(raw),
                                   let manifest = try? JSONDecoder().decode(ProjectManifest.self, from: Data(json.utf8)) {
                                    let (safe, v) = ProjectValidator.validate(manifest.files.map { ($0.path, $0.content) })
                                    if v.isValid { files = safe; validation = v; usedModel = model; break outer }
                                }
                                if pass == 0 {
                                    user = userPrompt + "\n\nYour previous reply was not a valid project JSON with an "
                                        + "index.html. Reply again with ONLY the JSON object described above."
                                }
                            } catch { lastError = error; break }
                        }
                    }
                    guard let files else {
                        throw lastError ?? CapabilityError.failed("The model did not produce a valid multi-file project.")
                    }

                    cont.yield(.status("validating"))
                    var payload: [String: Data] = [:]
                    for f in files { payload[f.path] = Data(f.content.utf8) }
                    let totalBytes = payload.values.reduce(0) { $0 + $1.count }
                    let artifact = Artifact(
                        kind: .webProject, mimeType: "text/html", entrypoint: "index.html",
                        metadata: ["fileCount": .int(files.count), "byteSize": .int(totalBytes),
                                   "selfContained": .bool(validation.findings.allSatisfy { !$0.contains("external") }),
                                   "files": .array(files.map { .string($0.path) })],
                        generatedBy: ArtifactProvenance(providerID: providerID, modelID: usedModel, capability: .projectGenerate),
                        validation: validation, preview: .staticSandbox)
                    let saved = try context.artifactStore.save(artifact, files: payload)
                    cont.yield(.planResolved(ExecutionPlan.single(
                        capability: req.capability, inputModalities: [.text], outputModality: .text,
                        providerID: providerID, modelID: usedModel, backend: .native,
                        rationale: ["Generated a \(files.count)-file static web project (\(usedModel)) — previewed in an isolated sandbox.",
                                    "Files: \(files.map { $0.path }.joined(separator: ", ")). No build/npm/network — static, self-contained."])))
                    cont.yield(.artifactProduced(saved))
                    cont.yield(.done(finishReason: validation.isValid ? "stop" : "invalid"))
                    cont.finish()
                } catch is CancellationError {
                    cont.yield(.failed(message: "project generation was cancelled")); cont.finish(throwing: CancellationError())
                } catch {
                    cont.yield(.failed(message: error.localizedDescription)); cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}
