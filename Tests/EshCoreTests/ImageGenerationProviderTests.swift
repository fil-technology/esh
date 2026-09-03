import Foundation
import Testing
@testable import EshCore

@Suite
struct ImageGenerationProviderTests {
    private func context() -> (ExecutionContext, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("esh-gen-\(UUID().uuidString)", isDirectory: true)
        return (ExecutionContext(root: PersistenceRoot(rootURL: dir),
                                 artifactStore: FileArtifactStore(rootURL: dir.appendingPathComponent("artifacts"))), dir)
    }

    @Test
    func producesImageArtifactFromTextPrompt() async throws {
        // Mock mflux: writes a fake PNG and reports a size + echoes the requested steps.
        let provider = ImageGenerationProvider(generate: { prompt, outPath, steps, _, _, _, _, _, _ in
            #expect(prompt.contains("a red cube"))
            #expect(steps == 8)
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: outPath))
            return (512, 512)
        })
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [provider]), context: ctx)
        let result = try await svc.executeCollecting(ExecutionRequest(
            capability: .imageGenerate, inputs: [.text("a red cube")], output: .init(modality: .image)))
        let art = try #require(result.outputs.first)
        #expect(art.kind == .image)
        #expect(art.mimeType == "image/png")
        #expect(art.metadata["width"] == .int(512))
        let bytes = try #require(try ctx.artifactStore.data(id: art.id, file: "result.png"))
        #expect(!bytes.isEmpty)
    }

    @Test
    func requiresATextPrompt() async {
        let provider = ImageGenerationProvider(generate: { _, _, _, _, _, _, _, _, _ in (1, 1) })
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [provider]), context: ctx)
        await #expect(throws: CapabilityError.self) {
            _ = try await svc.executeCollecting(ExecutionRequest(
                capability: .imageGenerate, inputs: [.text("   ")], output: .init(modality: .image)))
        }
    }

    @Test
    func surfacesMemoryStopAsACleanFailure() async {
        // The bridge stops a run and reports low memory; the provider must surface it, not crash.
        let provider = ImageGenerationProvider(generate: { _, _, _, _, _, _, _, _, _ in
            throw CapabilityError.failed("image generation stopped to protect the machine: low memory")
        })
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [provider]), context: ctx)
        await #expect(throws: CapabilityError.self) {
            _ = try await svc.executeCollecting(ExecutionRequest(
                capability: .imageGenerate, inputs: [.text("a red cube")], output: .init(modality: .image)))
        }
    }

    @Test
    func dispatchedForImageGenerateTextToImage() {
        let reg = CapabilityRegistry(providers: [ImageGenerationProvider(generate: { _, _, _, _, _, _, _, _, _ in (1, 1) })])
        #expect(reg.providers(for: .imageGenerate, inputs: [.text], output: .image).count == 1)
        #expect(reg.providers(for: .imageGenerate, inputs: [.image], output: .image).isEmpty)
    }
}
