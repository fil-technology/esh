import Foundation
import Testing
@testable import EshCore

@Suite
struct EmbeddingProvidersTests {
    private func context() -> (ExecutionContext, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("esh-emb-\(UUID().uuidString)", isDirectory: true)
        return (ExecutionContext(root: PersistenceRoot(rootURL: dir),
                                 artifactStore: FileArtifactStore(rootURL: dir.appendingPathComponent("artifacts"))), dir)
    }

    @Test
    func embeddingProviderProducesTypedVectorArtifact() async throws {
        let provider = EmbeddingProvider(embed: { _, texts in texts.map { _ in [0.1, 0.2, 0.3] } })
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [provider]), context: ctx)
        let result = try await svc.executeCollecting(
            ExecutionRequest(capability: .languageEmbed,
                             inputs: [.text("hello"), .text("world")],
                             output: .embedding, model: "emb-model"))
        let art = try #require(result.outputs.first)
        #expect(art.kind == .embedding)
        #expect(art.metadata["dim"] == .int(3))
        #expect(art.metadata["count"] == .int(2))
        let bytes = try #require(try ctx.artifactStore.data(id: art.id, file: "embedding.json"))
        let obj = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect((obj["vectors"] as? [[Any]])?.count == 2)
        #expect(obj["dim"] as? Int == 3)
    }

    @Test
    func rerankProviderSortsAndLabelsDocuments() async throws {
        // Mock scores documents in reverse: last doc most relevant.
        let provider = RerankProvider(rerank: { _, _, docs in
            docs.enumerated().map { RerankHit(index: $0.offset, score: Double($0.offset)) }
        })
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [provider]), context: ctx)
        let result = try await svc.executeCollecting(
            ExecutionRequest(capability: .languageRerank,
                             inputs: [.text("q", role: "query"),
                                      .text("doc A", role: "document"),
                                      .text("doc B", role: "document"),
                                      .text("doc C", role: "document")],
                             output: .json, model: "reranker"))
        let art = try #require(result.outputs.first)
        #expect(art.kind == .ranked)
        #expect(art.metadata["count"] == .int(3))
        let bytes = try #require(try ctx.artifactStore.data(id: art.id, file: "ranked.json"))
        let arr = try #require(try JSONSerialization.jsonObject(with: bytes) as? [[String: Any]])
        // Highest score (index 2 = "doc C") ranks first.
        #expect(arr.first?["index"] as? Int == 2)
        #expect(arr.first?["document"] as? String == "doc C")
    }

    @Test
    func rerankRequiresQueryAndDocuments() async {
        let provider = RerankProvider(rerank: { _, _, _ in [] })
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [provider]), context: ctx)
        await #expect(throws: CapabilityError.self) {
            _ = try await svc.executeCollecting(
                ExecutionRequest(capability: .languageRerank, inputs: [.text("only a query")], output: .json))
        }
    }
}
