import Foundation
import Testing
@testable import EshCore

@Suite
struct ImageEditProviderTests {
    private func context() -> (ExecutionContext, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("esh-edit-\(UUID().uuidString)", isDirectory: true)
        return (ExecutionContext(root: PersistenceRoot(rootURL: dir),
                                 artifactStore: FileArtifactStore(rootURL: dir.appendingPathComponent("artifacts"))), dir)
    }

    @Test
    func producesEditedImageArtifactWithLicenseProvenance() async throws {
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        let provider = ImageEditProvider(edit: { _, outPath, instruction, backend, _, _, _, _ in
            #expect(instruction == "change the sky to sunset")
            #expect(backend == .flux2Klein)   // universal-fit default (Apache-2.0, runs on 32GB)
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: outPath))
            return ImageEditResult(width: 1024, height: 1024, backend: "flux2-klein", model: "flux2-klein-4b",
                                   license: "apache-2.0", commercial: true)
        })
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [provider]), context: ctx)
        let result = try await svc.executeCollecting(ExecutionRequest(
            capability: .imageEdit,
            inputs: [.attachment(EshAttachment(kind: .image, mimeType: "image/png", base64: Data([1,2]).base64EncodedString())),
                     .text("change the sky to sunset")],
            output: .init(modality: .image)))
        let art = try #require(result.outputs.first)
        #expect(art.kind == .image)
        #expect(art.metadata["license"] == .string("apache-2.0"))
        #expect(art.metadata["commercial"] == .bool(true))
        #expect(art.generatedBy.capability == .imageEdit)
    }

    @Test
    func requiresAnImageAndAnInstruction() async {
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        let provider = ImageEditProvider(edit: { _, _, _, _, _, _, _, _ in
            ImageEditResult(width: 1, height: 1, backend: "qwen-edit", model: "m", license: "apache-2.0", commercial: true) })
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [provider]), context: ctx)
        // No image → error.
        await #expect(throws: CapabilityError.self) {
            _ = try await svc.executeCollecting(ExecutionRequest(capability: .imageEdit, inputs: [.text("change the sky")], output: .init(modality: .image)))
        }
        // Image but no instruction → error.
        await #expect(throws: CapabilityError.self) {
            _ = try await svc.executeCollecting(ExecutionRequest(capability: .imageEdit,
                inputs: [.attachment(EshAttachment(kind: .image, mimeType: "image/png", base64: Data([1]).base64EncodedString()))],
                output: .init(modality: .image)))
        }
    }

    @Test
    func dispatchedForEditImageToImage() {
        let reg = CapabilityRegistry(providers: [ImageEditProvider(edit: { _, _, _, _, _, _, _, _ in
            ImageEditResult(width: 1, height: 1, backend: "qwen-edit", model: "m", license: "apache-2.0", commercial: true) })])
        #expect(reg.providers(for: .imageEdit, inputs: [.image, .text], output: .image).count == 1)
    }

    // MARK: - Tier-0 routing: edit vs segment vs clarify (preserve Router Auto safety)

    private let router = DeterministicIntentRouter()
    private func route(_ msg: String) -> CapabilityIntent { router.route(message: msg, inputModalities: [.image]) }

    @Test func concreteEditInstructionsRouteToImageEdit() {
        for m in ["remove the person on the left", "change the sky to sunset",
                  "replace the red car with a blue one", "make it look like it was taken at night",
                  "extend the image to the left", "change only the shirt color"] {
            let r = router.route(message: m, inputModalities: [.image])
            #expect(r.action == .executeCapability, "\(m) → \(r.action)")
            #expect(r.capability == .imageEdit, "\(m) → \(String(describing: r.capability))")
        }
    }

    @Test func backgroundRemovalStaysSegmentation() {
        #expect(route("remove the background").capability == .imageSegment)
        #expect(route("make the background transparent").capability != .imageEdit)   // segment, not edit
    }

    @Test func vagueImproveStaysClarify() {
        let r = route("make this better")
        #expect(r.action == .clarify)
        #expect(r.clarifyKind == .ambiguous)
    }

    @Test func upscaleStaysUpscaleNotEdit() {
        #expect(route("upscale this 2x").capability == .imageUpscale)
    }
}
