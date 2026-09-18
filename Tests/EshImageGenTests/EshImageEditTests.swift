import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
import Hub
import EshCore
import EshRuntime
@testable import EshImageGen

// Deterministic tests for the native INSTRUCT image.edit provider (InstructPix2Pix) wiring
// (discovery/progress/artifact/cancellation/errors/input-resolution/params) using a mock engine. This
// provider must advertise `image.edit` (content-preserving instruct edit) with an in-process `.mlx` backend,
// so it WINS over the Python compat `image.edit` provider. The real on-device pixel behavior is validated
// separately (standalone package VALIDATION.md + esh-level dogfood).
private func editPNG() -> Data {
    let cs = CGColorSpaceCreateDeviceRGB()
    let c = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                      space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, c.makeImage()!, nil); CGImageDestinationFinalize(dest)
    return data as Data
}
private func mockEdit(steps: Int = 3, png: Data) -> InstructImageEditFn {
    { _, _, _ in AsyncThrowingStream { c in
        for i in 1...steps { c.yield(.progress(Double(i) / Double(steps))) }
        c.yield(.image(png)); c.finish()
    } }
}
private func tmpImage() -> String {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
    try? editPNG().write(to: u); return u.path
}
private func editCtx() -> ExecutionContext {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    return ExecutionContext(root: PersistenceRoot(rootURL: u), artifactStore: FileArtifactStore(root: PersistenceRoot(rootURL: u)))
}
private func editReq(imagePath: String?, base64: String? = nil, prompt: String) -> ResolvedExecutionRequest {
    var inputs: [CapabilityInput] = []
    if let imagePath { inputs.append(.attachment(EshAttachment(kind: .image, uri: "file://" + imagePath))) }
    if let base64 { inputs.append(.attachment(EshAttachment(kind: .image, base64: base64))) }
    if !prompt.isEmpty { inputs.append(.text(prompt)) }
    return ResolvedExecutionRequest(request: ExecutionRequest(capability: .imageEdit,
        inputs: inputs, output: OutputSpec(modality: .image, format: "image/png")))
}
private func collectEdit(_ s: AsyncThrowingStream<CapabilityEvent, Error>) async -> (artifacts: Int, progress: [Double], failed: String?) {
    var a = 0; var p: [Double] = []; var f: String?
    do { for try await e in s {
        if case .artifactProduced = e { a += 1 }
        if case .progress(let v) = e { p.append(v) }
        if case .failed(let m) = e { f = m }
    } } catch { f = "\(error)" }
    return (a, p, f)
}

@Suite struct EshImageEditTests {
    @Test func descriptorIsNativeInstructEditNotRestyle() {
        let p = MLXInstructImageEditProvider(modelID: "m", supported: true, edit: mockEdit(png: editPNG()))
        #expect(p.descriptor.capabilities == [.imageEdit])
        // Must NOT be the restyle capability, and MUST be in-process (.mlx) so it wins over compat .python.
        #expect(!p.descriptor.capabilities.contains(.imageRestyle))
        #expect(p.descriptor.backend == .mlx)
        #expect(p.descriptor.backend.isInProcess)
        #expect(p.descriptor.acceptedInputs.contains(.image) && p.descriptor.acceptedInputs.contains(.text))
        #expect(p.descriptor.producedOutputs == [.image])
    }

    @Test func editsImageWithProgress() async {
        let p = MLXInstructImageEditProvider(modelID: "m", supported: true, edit: mockEdit(png: editPNG()))
        let out = await collectEdit(p.execute(editReq(imagePath: tmpImage(), prompt: "turn the car red"), context: editCtx()))
        #expect(out.artifacts == 1)
        #expect(out.progress.last == 1.0)
        #expect(out.failed == nil)
    }

    @Test func missingImageFailsHonestly() async {
        let p = MLXInstructImageEditProvider(modelID: "m", supported: true, edit: mockEdit(png: editPNG()))
        let out = await collectEdit(p.execute(editReq(imagePath: nil, prompt: "make it red"), context: editCtx()))
        #expect(out.artifacts == 0 && (out.failed?.contains("image input") ?? false))
    }

    @Test func missingInstructionFailsHonestly() async {
        let p = MLXInstructImageEditProvider(modelID: "m", supported: true, edit: mockEdit(png: editPNG()))
        let out = await collectEdit(p.execute(editReq(imagePath: tmpImage(), prompt: ""), context: editCtx()))
        #expect(out.artifacts == 0 && (out.failed?.contains("instruction") ?? false))
    }

    @Test func discoveryRequiresDownloadThenReady() async {
        let p = MLXInstructImageEditProvider(modelID: "m", supported: true, edit: mockEdit(png: editPNG()))
        if case .requiresDownload = p.reportedAvailability(for: .imageEdit) {} else { Issue.record("expected requiresDownload initially") }
        _ = await collectEdit(p.execute(editReq(imagePath: tmpImage(), prompt: "red"), context: editCtx()))
        if case .ready = p.reportedAvailability(for: .imageEdit) {} else { Issue.record("expected ready after a run") }
    }

    @Test func unsupportedReportsHonestly() async {
        let p = MLXInstructImageEditProvider(modelID: "m", supported: false, edit: mockEdit(png: editPNG()))
        if case .unsupportedOnPlatform = p.reportedAvailability(for: .imageEdit) {} else { Issue.record("expected unsupportedOnPlatform") }
    }

    @Test func fileURIInputResolves() {
        let path = tmpImage()
        let inputs: [CapabilityInput] = [.attachment(EshAttachment(kind: .image, uri: "file://" + path)), .text("x")]
        #expect(MLXInstructImageEditProvider.resolveImageInput(inputs)?.path == path)
    }

    @Test func base64InputResolvesToReadableTempFile() {
        let b64 = editPNG().base64EncodedString()
        let inputs: [CapabilityInput] = [.attachment(EshAttachment(kind: .image, base64: b64)), .text("x")]
        let resolved = MLXInstructImageEditProvider.resolveImageInput(inputs)
        #expect(resolved != nil)
        if let r = resolved {
            #expect(FileManager.default.fileExists(atPath: r.path))
            // The decoded file is a real PNG the loader can open.
            #expect(CGImageSourceCreateWithURL(URL(fileURLWithPath: r.path) as CFURL, nil) != nil)
            r.cleanup?()
            #expect(!FileManager.default.fileExists(atPath: r.path))
        }
    }

    @Test func paramsDefaultsAreValidatedInstructSettings() {
        let d = MLXInstructImageEditProvider.params(from: [:])
        #expect(d.steps == 20 && d.textGuidance == 7.0 && d.imageGuidance == 1.5 && d.maximumEdge == 512)
        #expect(d.seed == nil && d.negativePrompt == "")
    }

    @Test func paramsAcceptEshAndDiffusersOptionNames() {
        let o = MLXInstructImageEditProvider.params(from: [
            "steps": .int(30), "guidanceScale": .double(9), "imageGuidanceScale": .double(2.0),
            "seed": .int(42), "negativePrompt": .string("blurry"), "maximumEdge": .int(1024)])
        #expect(o.steps == 30 && o.textGuidance == 9 && o.imageGuidance == 2.0)
        #expect(o.seed == 42 && o.negativePrompt == "blurry" && o.maximumEdge == 1024)
    }

    @Test func providersFactoryYieldsNativeInstructEditProvider() {
        let ps = EshImageEdit.providers()
        #expect(ps.count == 1)
        #expect(ps.first?.descriptor.capabilities == [.imageEdit])
        #expect(ps.first?.descriptor.backend == .mlx)
    }

    @Test func instructPix2PixSelfHostedIsTokenFreeAndPinned() {
        let m = SelfHostedModel.instructPix2Pix()
        #expect(m.modelID == "timbrooks/instruct-pix2pix")
        #expect(m.baseURL.absoluteString.contains("instruct-pix2pix/resolve/main"))
        let paths = Set(m.files.map(\.relativePath))
        for req in ["unet/config.json", "unet/diffusion_pytorch_model.fp16.safetensors",
                    "text_encoder/config.json", "text_encoder/model.fp16.safetensors",
                    "vae/config.json", "vae/diffusion_pytorch_model.fp16.safetensors",
                    "scheduler/scheduler_config.json", "tokenizer/vocab.json", "tokenizer/merges.txt"] {
            #expect(paths.contains(req))
        }
        #expect(m.files.count == 9)
        // The three multi-hundred-MB fp16 safetensors are integrity-pinned; small JSON/tokenizer files are not.
        let pinned = Set(m.files.filter { $0.sha256 != nil }.map(\.relativePath))
        #expect(pinned == ["unet/diffusion_pytorch_model.fp16.safetensors",
                           "text_encoder/model.fp16.safetensors",
                           "vae/diffusion_pytorch_model.fp16.safetensors"])
        // The validated UNet fp16 hash (the corruption guard).
        let unet = m.files.first { $0.relativePath == "unet/diffusion_pytorch_model.fp16.safetensors" }!
        #expect(unet.sha256 == "0d6bbc0a95dd125196d327a660b43d24c56f433eb30d2776f1327fb86bd38f78")
    }
}
