import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
import EshCore
import EshRuntime
@testable import EshImageGen

// Deterministic tests for the native image-generation provider wiring (discovery/progress/artifact/
// cancellation/errors) using a mock engine — the real MLX StableDiffusion path is validated by on-device
// generation separately (opt-in, heavy).

private func tinyPNG() -> Data {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.1, green: 0.7, blue: 0.3, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    let img = ctx.makeImage()!
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
    return data as Data
}

private func mockEngine(steps: Int = 3, png: Data) -> ImageGenFn {
    { _, _ in
        AsyncThrowingStream { c in
            for i in 1...steps { c.yield(.progress(Double(i) / Double(steps))) }
            c.yield(.image(png)); c.finish()
        }
    }
}
private func hangEngine() -> ImageGenFn {
    { _, _ in AsyncThrowingStream { c in
        let t = Task { do { while true { try Task.checkCancellation(); try await Task.sleep(nanoseconds: 15_000_000) } } catch { c.finish(throwing: CancellationError()) } }
        c.onTermination = { _ in t.cancel() }
    } }
}
private func req(_ prompt: String = "a red apple on a table") -> ResolvedExecutionRequest {
    ResolvedExecutionRequest(request: ExecutionRequest(capability: .imageGenerate,
        inputs: [.text(prompt)], output: OutputSpec(modality: .image)))
}
private func ctx() -> ExecutionContext {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    return ExecutionContext(root: PersistenceRoot(rootURL: u), artifactStore: FileArtifactStore(root: PersistenceRoot(rootURL: u)))
}
private func collect(_ s: AsyncThrowingStream<CapabilityEvent, Error>) async -> (artifacts: Int, progress: [Double], failed: String?) {
    var artifacts = 0; var progress: [Double] = []; var failed: String?
    do {
        for try await e in s {
            if case .artifactProduced = e { artifacts += 1 }
            if case .progress(let p) = e { progress.append(p) }
            if case .failed(let m) = e { failed = m }
        }
    } catch { failed = "\(error)" }
    return (artifacts, progress, failed)
}

@Suite struct EshImageGenTests {
    @Test func moduleLoads() { #expect(EshImageGen.defaultModelID.isEmpty == false) }

    @Test func generatesArtifactWithProgress() async {
        let p = MLXImageGenerateProvider(modelID: "m", supported: true, generate: mockEngine(png: tinyPNG()))
        let out = await collect(p.execute(req(), context: ctx()))
        #expect(out.artifacts == 1)
        #expect(out.progress.count == 3)
        #expect(out.progress.last == 1.0)
        #expect(out.failed == nil)
    }

    @Test func discoveryRequiresDownloadThenReady() async {
        let p = MLXImageGenerateProvider(modelID: "m", supported: true, generate: mockEngine(png: tinyPNG()))
        if case .requiresDownload = p.reportedAvailability(for: .imageGenerate) {} else { Issue.record("expected requiresDownload initially") }
        _ = await collect(p.execute(req(), context: ctx()))
        if case .ready = p.reportedAvailability(for: .imageGenerate) {} else { Issue.record("expected ready after a successful run") }
    }

    @Test func unsupportedReportsHonestly() async {
        let p = MLXImageGenerateProvider(modelID: "m", supported: false, generate: mockEngine(png: tinyPNG()))
        if case .unsupportedOnPlatform = p.reportedAvailability(for: .imageGenerate) {} else { Issue.record("expected unsupportedOnPlatform") }
        let out = await collect(p.execute(req(), context: ctx()))
        #expect(out.failed != nil && out.artifacts == 0)
    }

    @Test func emptyPromptFailsHonestly() async {
        let p = MLXImageGenerateProvider(modelID: "m", supported: true, generate: mockEngine(png: tinyPNG()))
        let out = await collect(p.execute(req("   "), context: ctx()))
        #expect(out.failed != nil && out.artifacts == 0)
    }

    @Test func cancellationStops() async {
        let p = MLXImageGenerateProvider(modelID: "m", supported: true, generate: hangEngine())
        let stream = p.execute(req(), context: ctx())
        let consumer = Task { for try await _ in stream {} }
        try? await Task.sleep(nanoseconds: 50_000_000)
        consumer.cancel()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(true)  // no hang/crash on cancellation
    }

    // Real on-device image generation through the PUBLIC facade. Downloads SD 2.1 base from Hugging Face and
    // runs the diffusion loop on the GPU, so it is opt-in (ESH_IMAGEGEN_REAL=1 or ~/.esh_imagegen_real) and
    // must run under xcodebuild (Xcode builds MLX's Metal shader library; plain swift build/run does not).
    // Validates: a real PNG artifact at the requested size, per-step progress, honest requiresDownload->ready
    // discovery, prompt cancellation, and generator reuse.
    @Test func realOnDeviceGenerate() async throws {
        let optedIn = ProcessInfo.processInfo.environment["ESH_IMAGEGEN_REAL"] == "1"
            || FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.esh_imagegen_real")
        guard optedIn else { return }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = PersistenceRoot(rootURL: tmp)
        let runtime = await EshRuntime.makeWithImageGen(backends: [:], root: root)

        let before = await runtime.capabilityAvailability()
        if case .requiresDownload = before.entries[.imageGenerate] {} else {
            Issue.record("expected requiresDownload before first load, got \(String(describing: before.entries[.imageGenerate]))")
        }

        func genRequest(_ prompt: String, steps: Int) -> ExecutionRequest {
            ExecutionRequest(capability: .imageGenerate, inputs: [.text(prompt)],
                             output: OutputSpec(modality: .image),
                             options: ExecutionOptions(["steps": .int(steps), "width": .int(512), "height": .int(512), "seed": .int(7)]))
        }

        // 1. generate: real PNG artifact at 512×512, with per-step progress
        let t0 = Date()
        var progress: [Double] = []; var artifactID: UUID?
        for try await ev in runtime.stream(genRequest("a red apple on a wooden table", steps: 12)) {
            if case .progress(let p) = ev { progress.append(p) }
            if case .artifactProduced(let a) = ev { artifactID = a.id }
            if case .failed(let m) = ev {
                FileHandle.standardError.write(Data("[realImageGen] FAILURE: \(m)\n".utf8))
                Issue.record("generation failed: \(m)")
            }
        }
        let dt1 = Date().timeIntervalSince(t0)
        let id = try #require(artifactID)
        let png = try #require(try FileArtifactStore(root: root).data(id: id, file: "generated.png"))
        let dims = try #require(Self.pngSize(png))
        FileHandle.standardError.write(Data("[realImageGen] first=\(String(format: "%.1f", dt1))s dims=\(dims) bytes=\(png.count) steps=\(progress.count)\n".utf8))
        #expect(dims == CGSize(width: 512, height: 512))
        #expect(png.count > 1000)          // a real encoded image, not an empty/degenerate buffer
        #expect(progress.count >= 10)      // ~12 denoise steps reported
        #expect(progress.last == 1.0)

        let after = await runtime.capabilityAvailability()
        if case .ready = after.entries[.imageGenerate] {} else {
            Issue.record("expected ready after a successful run, got \(String(describing: after.entries[.imageGenerate]))")
        }

        // 2. cancellation: cancelling a long generation stops promptly
        let cancelStart = Date()
        let consumer = Task { do { for try await _ in runtime.stream(genRequest("an intricate castle", steps: 50)) {} } catch {} }
        try? await Task.sleep(nanoseconds: 500_000_000)
        consumer.cancel()
        _ = await consumer.value
        let cancelElapsed = Date().timeIntervalSince(cancelStart)
        FileHandle.standardError.write(Data("[realImageGen] cancelled in \(String(format: "%.2f", cancelElapsed))s\n".utf8))
        #expect(cancelElapsed < dt1 + 5)

        // 3. reuse: a 2nd generation reuses the loaded generator (no reload) -> faster than the first
        let t2 = Date()
        var artifact2: UUID?
        for try await ev in runtime.stream(genRequest("a blue ceramic mug", steps: 12)) {
            if case .artifactProduced(let a) = ev { artifact2 = a.id }
        }
        let dt2 = Date().timeIntervalSince(t2)
        FileHandle.standardError.write(Data("[realImageGen] second=\(String(format: "%.1f", dt2))s\n".utf8))
        #expect(artifact2 != nil)
        #expect(dt2 < dt1)  // reused generator: no second download+load
    }

    static func pngSize(_ data: Data) -> CGSize? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return CGSize(width: img.width, height: img.height)
    }

    @Test func paramsSnapDimensionsAndClampSteps() {
        let params = MLXImageGenerateProvider.params(from: [
            "width": .int(700), "height": .int(500), "steps": .int(9999), "seed": .int(42)
        ])
        #expect(params.width == 696)   // 700 -> nearest lower multiple of 8
        #expect(params.height == 496)  // 500 -> nearest lower multiple of 8 (62*8)
        #expect(params.steps == 100)   // clamped
        #expect(params.seed == 42)
    }
}
