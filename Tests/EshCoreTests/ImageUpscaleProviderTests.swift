import Foundation
import Testing
@testable import EshCore

@Suite
struct ImageUpscaleProviderTests {
    private func context() -> (ExecutionContext, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("esh-ups-\(UUID().uuidString)", isDirectory: true)
        return (ExecutionContext(root: PersistenceRoot(rootURL: dir),
                                 artifactStore: FileArtifactStore(rootURL: dir.appendingPathComponent("artifacts"))), dir)
    }

    @Test
    func producesLargerImageArtifactFromImageInput() async throws {
        let provider = ImageUpscaleProvider(upscale: { _, outPath, resolution, _, _ in
            #expect(resolution == 2048)
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: outPath))
            return (2048, 2048)
        })
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [provider]), context: ctx)
        let result = try await svc.executeCollecting(ExecutionRequest(
            capability: .imageUpscale,
            inputs: [.attachment(EshAttachment(kind: .image, mimeType: "image/png", base64: Data([1,2]).base64EncodedString()))],
            output: .init(modality: .image),
            options: ExecutionOptions(["resolution": .int(2048)])))
        let art = try #require(result.outputs.first)
        #expect(art.kind == .image)
        #expect(art.metadata["width"] == .int(2048))
    }

    @Test
    func requiresAnImage() async {
        let provider = ImageUpscaleProvider(upscale: { _, _, _, _, _ in (1, 1) })
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [provider]), context: ctx)
        await #expect(throws: CapabilityError.self) {
            _ = try await svc.executeCollecting(ExecutionRequest(
                capability: .imageUpscale, inputs: [.text("no image")], output: .init(modality: .image)))
        }
    }

    @Test
    func dispatchedForUpscaleImageToImage() {
        let reg = CapabilityRegistry(providers: [ImageUpscaleProvider(upscale: { _, _, _, _, _ in (1, 1) })])
        #expect(reg.providers(for: .imageUpscale, inputs: [.image], output: .image).count == 1)
        #expect(reg.providers(for: .imageUpscale, inputs: [.text], output: .image).isEmpty)
    }
}
