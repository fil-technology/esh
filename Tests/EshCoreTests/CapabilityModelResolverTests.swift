import Foundation
import Testing
@testable import EshCore

@Suite
struct CapabilityModelResolverTests {
    private func install(_ id: String, task: ModelTask, capabilities: ModelCapabilities,
                         inputs: [ModelModality] = [.text], outputs: [ModelModality] = [.text]) -> ModelInstall {
        let spec = ModelSpec(id: id, displayName: id, backend: .mlx,
                             source: ModelSource(kind: .localPath, reference: "local/\(id)"),
                             task: task, inputModalities: inputs, outputModalities: outputs, capabilities: capabilities)
        return ModelInstall(id: id, spec: spec, installPath: "/tmp/\(id)", sizeBytes: 1, backendFormat: "mlx")
    }

    private let resolver = CapabilityModelResolver()

    @Test
    func picksVisionModelForImageUnderstand() {
        let installs = [
            install("text-llm", task: .text, capabilities: .textGeneration),
            install("vlm", task: .vision,
                    capabilities: ModelCapabilities(vision: VisionCapabilities(supportsImageUnderstanding: true)),
                    inputs: [.text, .image])
        ]
        #expect(resolver.resolveModelID(capability: .imageUnderstand, from: installs) == "vlm")
    }

    @Test
    func picksEmbeddingModelForEmbed() {
        let installs = [
            install("text-llm", task: .text, capabilities: .textGeneration),
            install("emb", task: .embedding,
                    capabilities: ModelCapabilities(embedding: EmbeddingCapabilities(supportsEmbedding: true, dimensions: 768)),
                    outputs: [.embedding])
        ]
        #expect(resolver.resolveModelID(capability: .languageEmbed, from: installs) == "emb")
    }

    @Test
    func chatFallsBackToAnyTextModelWhenUndeclared() {
        // A text model with no explicit capabilities still serves chat-class capabilities.
        let installs = [install("plain", task: .text, capabilities: ModelCapabilities())]
        #expect(resolver.resolveModelID(capability: .languageGenerate, from: installs) == "plain")
        #expect(resolver.resolveModelID(capability: .vectorGenerate, from: installs) == "plain")
    }

    @Test
    func nonTextCapabilityRequiresDeclaredModel() {
        // No embedding model installed → no resolution (honest nil), never a text model.
        let installs = [install("text-llm", task: .text, capabilities: .textGeneration)]
        #expect(resolver.resolveModelID(capability: .languageEmbed, from: installs) == nil)
        #expect(resolver.resolveModelID(capability: .imageUnderstand, from: installs) == nil)
    }

    @Test
    func ocrAndUnknownNeedNoModel() {
        let installs = [install("text-llm", task: .text, capabilities: .textGeneration)]
        #expect(resolver.requiredFilter(for: .imageOCR) == nil)          // Apple Vision, no model
        #expect(resolver.resolveModelID(capability: .imageOCR, from: installs) == nil)
        #expect(resolver.resolveModelID(capability: .imageGenerate, from: installs) == nil)
    }
}
