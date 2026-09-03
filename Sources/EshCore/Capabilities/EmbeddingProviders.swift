import Foundation

// esh 2.1 UCMR, Stage 1b — embeddings + reranking CapabilityProviders. These ride the already-bundled
// llama-server (--embeddings / --reranking), so esh gains retrieval primitives with no new runtime dep.
// Typed non-text outputs: an embedding vector set and a ranked list (the second substantially-different
// provider that, with text→SVG, proves the capability abstraction — release gate).

/// A reranked document result (public-facing; independent of the internal server type).
public struct RerankHit: Sendable, Equatable {
    public let index: Int
    public let score: Double
    public init(index: Int, score: Double) { self.index = index; self.score = score }
}

/// Owns/caches auxiliary llama-server instances (one per model+mode) and exposes embed/rerank.
public actor LlamaAuxRuntimeManager {
    public typealias Resolver = @Sendable (_ modelID: String?) throws -> (executable: URL, modelPath: String)
    private let resolve: Resolver
    private var servers: [String: LlamaAuxServerProcess] = [:]

    public init(resolve: @escaping Resolver) { self.resolve = resolve }

    public func embed(modelID: String?, texts: [String]) async throws -> [[Float]] {
        try await server(modelID: modelID, mode: .embeddings).embed(texts)
    }
    public func rerank(modelID: String?, query: String, documents: [String]) async throws -> [RerankHit] {
        let hits = try await server(modelID: modelID, mode: .reranking).rerank(query: query, documents: documents)
        return hits.map { RerankHit(index: $0.index, score: $0.score) }
    }

    private func server(modelID: String?, mode: LlamaAuxServerProcess.Mode) async throws -> LlamaAuxServerProcess {
        let resolved = try resolve(modelID)
        let key = "\(mode)|\(resolved.modelPath)"
        if let existing = servers[key], existing.isAlive { return existing }
        servers[key]?.shutdown()
        let server = try LlamaAuxServerProcess(executableURL: resolved.executable, modelPath: resolved.modelPath, mode: mode)
        try await server.start()
        servers[key] = server
        return server
    }

    public func shutdown() { for s in servers.values { s.shutdown() }; servers.removeAll() }
}

public struct EmbeddingProvider: CapabilityProvider {
    public typealias EmbedFn = @Sendable (_ modelID: String?, _ texts: [String]) async throws -> [[Float]]
    public let descriptor: CapabilityProviderDescriptor
    private let embed: EmbedFn

    public init(id: String = "embeddings", embed: @escaping EmbedFn) {
        self.descriptor = CapabilityProviderDescriptor(
            id: id, capabilities: [.languageEmbed], acceptedInputs: [.text], producedOutputs: [.embedding],
            backend: .gguf, streaming: false, structuredOutput: true, requiredPrivilege: .artifactOnly, previewMode: .none)
        self.embed = embed
    }

    public func execute(_ request: ResolvedExecutionRequest, context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        let req = request.request
        let embed = self.embed
        let providerID = descriptor.id
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    let texts = req.inputs.compactMap { if case .text(let t) = $0.payload { return t } else { return nil } }
                    guard !texts.isEmpty else { throw CapabilityError.failed("embeddings require at least one text input") }
                    cont.yield(.status("embedding \(texts.count) input(s)"))
                    let vectors = try await embed(req.model, texts)
                    let dim = vectors.first?.count ?? 0
                    let payload: [String: Any] = ["model": req.model ?? "", "dim": dim, "count": vectors.count,
                                                  "vectors": vectors.map { $0.map { Double($0) } }]
                    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                    let artifact = Artifact(
                        kind: .embedding, mimeType: "application/json", entrypoint: "embedding.json",
                        metadata: ["dim": .int(dim), "count": .int(vectors.count)],
                        generatedBy: ArtifactProvenance(providerID: providerID, modelID: req.model, capability: .languageEmbed),
                        validation: .valid, preview: .none)
                    let saved = try context.artifactStore.save(artifact, files: ["embedding.json": data])
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

public struct RerankProvider: CapabilityProvider {
    public typealias RerankFn = @Sendable (_ modelID: String?, _ query: String, _ documents: [String]) async throws -> [RerankHit]
    public let descriptor: CapabilityProviderDescriptor
    private let rerank: RerankFn

    public init(id: String = "rerank", rerank: @escaping RerankFn) {
        self.descriptor = CapabilityProviderDescriptor(
            id: id, capabilities: [.languageRerank], acceptedInputs: [.text], producedOutputs: [.json],
            backend: .gguf, streaming: false, structuredOutput: true, requiredPrivilege: .artifactOnly, previewMode: .none)
        self.rerank = rerank
    }

    public func execute(_ request: ResolvedExecutionRequest, context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        let req = request.request
        let rerank = self.rerank
        let providerID = descriptor.id
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    // query = the input roled "query" (else the first text); documents = inputs roled
                    // "document" plus any in options["documents"]; else the remaining text inputs.
                    let textInputs = req.inputs.filter { if case .text = $0.payload { return true } else { return false } }
                    func text(_ i: CapabilityInput) -> String { if case .text(let t) = i.payload { return t } else { return "" } }
                    let query = textInputs.first(where: { $0.role == "query" }).map(text)
                        ?? textInputs.first.map(text) ?? ""
                    var documents = textInputs.filter { $0.role == "document" }.map(text)
                    if case .array(let arr)? = req.options.values["documents"] {
                        documents += arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
                    }
                    if documents.isEmpty {
                        // Fall back to "first is query, rest are documents".
                        documents = Array(textInputs.dropFirst().map(text))
                    }
                    guard !query.isEmpty, !documents.isEmpty else {
                        throw CapabilityError.failed("rerank requires a query and at least one document")
                    }
                    cont.yield(.status("reranking \(documents.count) document(s)"))
                    let ranked = try await rerank(req.model, query, documents).sorted { $0.score > $1.score }
                    let payload: [[String: Any]] = ranked.map { r in
                        ["index": r.index, "score": r.score,
                         "document": (r.index >= 0 && r.index < documents.count) ? documents[r.index] : ""]
                    }
                    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                    let artifact = Artifact(
                        kind: .ranked, mimeType: "application/json", entrypoint: "ranked.json",
                        metadata: ["count": .int(ranked.count)],
                        generatedBy: ArtifactProvenance(providerID: providerID, modelID: req.model, capability: .languageRerank),
                        validation: .valid, preview: .none)
                    let saved = try context.artifactStore.save(artifact, files: ["ranked.json": data])
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
