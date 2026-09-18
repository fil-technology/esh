import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
import Hub
import EshCore
import EshRuntime
@testable import EshImageGen

// Deterministic tests for the native image.edit provider wiring (discovery/progress/artifact/cancellation/
// errors) using a mock engine. The real MLX SDXL-Turbo img2img path is validated on-device separately.
private func editPNG() -> Data {
    let cs = CGColorSpaceCreateDeviceRGB()
    let c = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                      space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setFillColor(CGColor(red: 0.2, green: 0.8, blue: 0.2, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, c.makeImage()!, nil); CGImageDestinationFinalize(dest)
    return data as Data
}
private func mockEdit(steps: Int = 3, png: Data) -> ImageEditFn {
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
private func editReq(imagePath: String?, prompt: String) -> ResolvedExecutionRequest {
    var inputs: [CapabilityInput] = []
    if let imagePath { inputs.append(.attachment(EshAttachment(kind: .image, uri: "file://" + imagePath))) }
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
    @Test func descriptorIsNativeImageEdit() {
        let p = MLXImageEditProvider(modelID: "m", supported: true, edit: mockEdit(png: editPNG()))
        #expect(p.descriptor.capabilities == [.imageEdit])
        #expect(p.descriptor.acceptedInputs.contains(.image) && p.descriptor.acceptedInputs.contains(.text))
        #expect(p.descriptor.producedOutputs == [.image])
        #expect(p.descriptor.backend == .mlx)
        #expect(p.descriptor.backend.isInProcess)   // native → wins over the Python compat image.edit
    }

    @Test func editsImageWithProgress() async {
        let p = MLXImageEditProvider(modelID: "m", supported: true, edit: mockEdit(png: editPNG()))
        let out = await collectEdit(p.execute(editReq(imagePath: tmpImage(), prompt: "make the apple green"), context: editCtx()))
        #expect(out.artifacts == 1)
        #expect(out.progress.last == 1.0)
        #expect(out.failed == nil)
    }

    @Test func missingImageFailsHonestly() async {
        let p = MLXImageEditProvider(modelID: "m", supported: true, edit: mockEdit(png: editPNG()))
        let out = await collectEdit(p.execute(editReq(imagePath: nil, prompt: "make it green"), context: editCtx()))
        #expect(out.artifacts == 0 && (out.failed?.contains("image input") ?? false))
    }

    @Test func missingInstructionFailsHonestly() async {
        let p = MLXImageEditProvider(modelID: "m", supported: true, edit: mockEdit(png: editPNG()))
        let out = await collectEdit(p.execute(editReq(imagePath: tmpImage(), prompt: ""), context: editCtx()))
        #expect(out.artifacts == 0 && (out.failed?.contains("instruction") ?? false))
    }

    @Test func discoveryRequiresDownloadThenReady() async {
        let p = MLXImageEditProvider(modelID: "m", supported: true, edit: mockEdit(png: editPNG()))
        if case .requiresDownload = p.reportedAvailability(for: .imageEdit) {} else { Issue.record("expected requiresDownload initially") }
        _ = await collectEdit(p.execute(editReq(imagePath: tmpImage(), prompt: "green"), context: editCtx()))
        if case .ready = p.reportedAvailability(for: .imageEdit) {} else { Issue.record("expected ready after a run") }
    }

    @Test func unsupportedReportsHonestly() async {
        let p = MLXImageEditProvider(modelID: "m", supported: false, edit: mockEdit(png: editPNG()))
        if case .unsupportedOnPlatform = p.reportedAvailability(for: .imageEdit) {} else { Issue.record("expected unsupportedOnPlatform") }
    }

    @Test func fileURIInputResolves() {
        let path = tmpImage()
        let inputs: [CapabilityInput] = [.attachment(EshAttachment(kind: .image, uri: "file://" + path)), .text("x")]
        #expect(MLXImageEditProvider.imageInputPath(inputs) == path)
    }

    @Test func paramsDefaultsSuitTurbo() {
        let d = MLXImageEditProvider.params(from: [:])
        #expect(d.strength == 0.7 && d.steps == 4 && d.maximumEdge == 768)
        let o = MLXImageEditProvider.params(from: ["strength": .double(0.4), "steps": .int(2), "maximumEdge": .int(1024)])
        #expect(o.strength == 0.4 && o.steps == 2 && o.maximumEdge == 1024)
    }

    @Test func providersFactoryYieldsNativeEditProvider() {
        let ps = EshImageEdit.providers()
        #expect(ps.count == 1)
        #expect(ps.first?.descriptor.capabilities == [.imageEdit])
        #expect(ps.first?.descriptor.backend == .mlx)
    }

    @Test func sdxlTurboSelfHostedModelIsTokenFreeAndPinned() {
        // Token-free source for the gated stabilityai/sdxl-turbo; modelID MUST equal the .sdxlTurbo preset id
        // so the loader finds the prefetched files locally.
        let m = SelfHostedModel.sdxlTurbo()
        #expect(m.modelID == "stabilityai/sdxl-turbo")
        #expect(m.baseURL.absoluteString.contains("sdxl-turbo/resolve/main"))
        let paths = Set(m.files.map(\.relativePath))
        // The exact file set the .sdxlTurbo preset loads (13 files incl. the SDXL second text encoder).
        for req in ["unet/config.json", "unet/diffusion_pytorch_model.safetensors",
                    "text_encoder/config.json", "text_encoder/model.safetensors",
                    "text_encoder_2/config.json", "text_encoder_2/model.safetensors",
                    "vae/config.json", "vae/diffusion_pytorch_model.safetensors",
                    "scheduler/scheduler_config.json",
                    "tokenizer/vocab.json", "tokenizer/merges.txt",
                    "tokenizer_2/vocab.json", "tokenizer_2/merges.txt"] {
            #expect(paths.contains(req))
        }
        #expect(m.files.count == 13)
        // The four multi-GB safetensors are integrity-pinned; small JSON/tokenizer files are not.
        let pinned = Set(m.files.filter { $0.sha256 != nil }.map(\.relativePath))
        #expect(pinned == ["unet/diffusion_pytorch_model.safetensors", "text_encoder/model.safetensors",
                           "text_encoder_2/model.safetensors", "vae/diffusion_pytorch_model.safetensors"])
    }

    @Test func providersAcceptSelfHostedSDXLTurbo() {
        // The consumer path that unblocks token-free image.edit in the sandbox.
        let ps = EshImageEdit.providers(selfHosted: .sdxlTurbo())
        #expect(ps.first?.descriptor.capabilities == [.imageEdit])
        #expect(ps.first?.descriptor.backend == .mlx)
    }

    @Test func sdxlTurboFetchesFP16ByDefaultFP32OptOut() {
        // Default = lighter fp16 (~7 GB): fetched from the .fp16 source, stored under the preset's fp32 name.
        let m = SelfHostedModel.sdxlTurbo()
        let unet = m.files.first { $0.relativePath == "unet/diffusion_pytorch_model.safetensors" }!
        #expect(unet.sourceRelativePath == "unet/diffusion_pytorch_model.fp16.safetensors")
        #expect(unet.sha256 == "48fa46161a745f48d4054df3fe13804ee255486bca893403b60373c188fd1bdb")
        // fp32 opt-out: fetches the non-fp16 file directly (no source remap), fp32 checksum.
        let f32 = SelfHostedModel.sdxlTurbo(fp16: false)
        let unet32 = f32.files.first { $0.relativePath == "unet/diffusion_pytorch_model.safetensors" }!
        #expect(unet32.sourceRelativePath == nil)
        #expect(unet32.sha256 == "1968fc61aa8449ab3d3f9b9a05bce88c611760c01e0c4a7a3785911b546fe582")
        // Loader-facing dest paths are identical for both variants.
        #expect(Set(m.files.map(\.relativePath)) == Set(f32.files.map(\.relativePath)))
        // All four fp16 weights carry a .fp16 source + a pin.
        let fp16Weights = m.files.filter { $0.sourceRelativePath?.contains(".fp16.safetensors") == true }
        #expect(fp16Weights.count == 4)
        #expect(fp16Weights.allSatisfy { $0.sha256 != nil })
    }

    @Test func selfHostedFetcherUsesSourceRelativePathForFetch() async throws {
        // The decoupling that makes fp16 possible: fetch from sourceRelativePath, store at relativePath.
        let mirror = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mirror) }
        try "FP16-CONTENT".data(using: .utf8)!.write(to: mirror.appendingPathComponent("w.fp16.bin"))
        let model = SelfHostedModel(modelID: "test/model", baseURL: mirror, files: [
            SelfHostedModel.Entry(relativePath: "w.bin", sourceRelativePath: "w.fp16.bin")
        ])
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        let hub = HubApi(downloadBase: cache)
        try await SelfHostedFetcher.prefetch(model, hub: hub) { _ in }
        let dest = hub.localRepoLocation(Hub.Repo(id: "test/model")).appending(path: "w.bin")
        #expect(FileManager.default.fileExists(atPath: dest.path))
        #expect((try? String(contentsOf: dest, encoding: .utf8)) == "FP16-CONTENT")
    }
}
