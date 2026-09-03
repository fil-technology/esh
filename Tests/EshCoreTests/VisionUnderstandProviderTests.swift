import Foundation
import Testing
@testable import EshCore

@Suite
struct VisionUnderstandProviderTests {
    private func context() -> (ExecutionContext, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("esh-vlm-\(UUID().uuidString)", isDirectory: true)
        return (ExecutionContext(root: PersistenceRoot(rootURL: dir),
                                 artifactStore: FileArtifactStore(rootURL: dir.appendingPathComponent("artifacts"))), dir)
    }

    @Test
    func returnsTextFromImageAndPrompt() async throws {
        let provider = VisionUnderstandProvider(understand: { paths, prompt, model, _ in
            "model=\(model) images=\(paths.count) prompt=\(prompt)"
        })
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [provider]), context: ctx)
        let png = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()  // any bytes; the mock won't read them
        let result = try await svc.executeCollecting(ExecutionRequest(
            capability: .imageUnderstand,
            inputs: [.text("what is this?"),
                     .attachment(EshAttachment(kind: .image, mimeType: "image/png", base64: png))],
            output: .text, model: "some-vlm"))
        #expect(result.text == "model=some-vlm images=1 prompt=what is this?")
    }

    @Test
    func requiresAModel() async {
        let provider = VisionUnderstandProvider(understand: { _, _, _, _ in "x" })
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [provider]), context: ctx)
        await #expect(throws: CapabilityError.self) {
            _ = try await svc.executeCollecting(ExecutionRequest(
                capability: .imageUnderstand,
                inputs: [.attachment(EshAttachment(kind: .image, base64: Data([1]).base64EncodedString()))],
                output: .text))  // no model
        }
    }

    @Test
    func requiresAnImage() async {
        let provider = VisionUnderstandProvider(understand: { _, _, _, _ in "x" })
        let (ctx, dir) = context(); defer { try? FileManager.default.removeItem(at: dir) }
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [provider]), context: ctx)
        await #expect(throws: CapabilityError.self) {
            _ = try await svc.executeCollecting(ExecutionRequest(
                capability: .imageUnderstand, inputs: [.text("no image here")], output: .text, model: "vlm"))
        }
    }

    @Test
    func materializeWritesBase64ToTempAndPassesThroughFileURIs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("esh-vlm-mat-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = PersistenceRoot(rootURL: dir)
        // base64 → temp file created.
        let (tempPath, isTemp) = try VisionUnderstandProvider.materialize(
            EshAttachment(kind: .image, mimeType: "image/png", base64: Data([1, 2, 3]).base64EncodedString()), root: root)
        #expect(isTemp)
        #expect(FileManager.default.fileExists(atPath: tempPath))
        #expect(tempPath.hasSuffix(".png"))
        // Existing uri → passed through, not temp.
        let (uriPath, isTemp2) = try VisionUnderstandProvider.materialize(
            EshAttachment(kind: .image, uri: tempPath), root: root)
        #expect(!isTemp2)
        #expect(uriPath == tempPath)
    }

    // The vision provider is a distinct capability dispatched only for image inputs.
    @Test
    func registryDispatchesVisionForImageInputs() {
        let reg = CapabilityRegistry(providers: [VisionUnderstandProvider(understand: { _, _, _, _ in "" })])
        #expect(reg.providers(for: .imageUnderstand, inputs: [.text, .image], output: .text).count == 1)
        #expect(reg.providers(for: .imageUnderstand, inputs: [.text], output: .text).count == 1) // text-only subset also allowed
        #expect(reg.providers(for: .languageGenerate, inputs: [.text], output: .text).isEmpty)   // not a text LLM
    }
}
