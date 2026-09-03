import Foundation
import Testing
@testable import EshCore

@Suite
struct AppleVisionOCRProviderTests {
    @Test
    func dispatchedForImageOCRWithNoModelRequired() {
        let reg = CapabilityRegistry(providers: [AppleVisionOCRProvider()])
        #expect(reg.providers(for: .imageOCR, inputs: [.image], output: .text).count == 1)
        // OCR is image-only; a text-only request does not match.
        #expect(reg.providers(for: .imageOCR, inputs: [.text], output: .text).isEmpty)
    }

    @Test
    func requiresAnImage() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("esh-ocr-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ctx = ExecutionContext(root: PersistenceRoot(rootURL: dir),
                                   artifactStore: FileArtifactStore(rootURL: dir.appendingPathComponent("artifacts")))
        let svc = CapabilityExecutionService(registry: CapabilityRegistry(providers: [AppleVisionOCRProvider()]), context: ctx)
        await #expect(throws: CapabilityError.self) {
            _ = try await svc.executeCollecting(
                ExecutionRequest(capability: .imageOCR, inputs: [.text("no image")], output: .text))
        }
    }

    // Recognizing a corrupt/non-image file surfaces a clear error rather than crashing.
    @Test
    func invalidImageThrows() {
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent("not-an-image-\(UUID().uuidString).png")
        try? Data("not a png".utf8).write(to: bad)
        defer { try? FileManager.default.removeItem(at: bad) }
        #expect(throws: (any Error).self) {
            _ = try AppleVisionOCRProvider.recognizeText(atPath: bad.path)
        }
    }
}
