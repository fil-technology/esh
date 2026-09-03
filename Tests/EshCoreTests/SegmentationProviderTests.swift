import Foundation
import Testing
@testable import EshCore

@Suite
struct SegmentationProviderTests {
    private func context() -> (ExecutionContext, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("esh-seg-\(UUID().uuidString)", isDirectory: true)
        return (ExecutionContext(root: PersistenceRoot(rootURL: dir),
                                 artifactStore: FileArtifactStore(rootURL: dir.appendingPathComponent("artifacts"))), dir)
    }

    @Test
    func producesImageArtifactFromImageInput() async throws {
        // Mock rembg: writes a fake PNG to outputPath and reports a size.
        let provider = SegmentationProvider(removeBackground: { _, outPath in
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: outPath))
            return (100, 80)
        })
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [provider]), context: ctx)
        let result = try await svc.executeCollecting(ExecutionRequest(
            capability: .imageSegment,
            inputs: [.attachment(EshAttachment(kind: .image, mimeType: "image/png", base64: Data([1, 2]).base64EncodedString()))],
            output: .init(modality: .image)))
        let art = try #require(result.outputs.first)
        #expect(art.kind == .image)
        #expect(art.mimeType == "image/png")
        #expect(art.metadata["width"] == .int(100))
        let bytes = try #require(try ctx.artifactStore.data(id: art.id, file: "result.png"))
        #expect(!bytes.isEmpty)
    }

    @Test
    func requiresAnImage() async {
        let provider = SegmentationProvider(removeBackground: { _, _ in (1, 1) })
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [provider]), context: ctx)
        await #expect(throws: CapabilityError.self) {
            _ = try await svc.executeCollecting(ExecutionRequest(
                capability: .imageSegment, inputs: [.text("no image")], output: .init(modality: .image)))
        }
    }

    @Test
    func dispatchedForSegmentAndEditImageOutput() {
        let reg = CapabilityRegistry(providers: [SegmentationProvider(removeBackground: { _, _ in (1, 1) })])
        #expect(reg.providers(for: .imageSegment, inputs: [.image], output: .image).count == 1)
        #expect(reg.providers(for: .imageEdit, inputs: [.image], output: .image).count == 1)
        #expect(reg.providers(for: .imageSegment, inputs: [.image], output: .text).isEmpty)
    }
}
