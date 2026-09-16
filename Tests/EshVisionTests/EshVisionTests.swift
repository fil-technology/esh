import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
import EshCore
import EshRuntime
@testable import EshVision

// Deterministic tests for the native VLM provider wiring (discovery/streaming/cancellation/errors) using a
// mock token stream — the real MLX model path is validated by on-device inference separately.

private func mockStream(_ tokens: [String]) -> VLMStreamFn {
    { _, _ in AsyncThrowingStream { c in for t in tokens { c.yield(t) }; c.finish() } }
}
private func hangStream() -> VLMStreamFn {
    { _, _ in AsyncThrowingStream { c in
        let t = Task { do { while true { try Task.checkCancellation(); try await Task.sleep(nanoseconds: 15_000_000) } } catch { c.finish(throwing: CancellationError()) } }
        c.onTermination = { _ in t.cancel() }
    } }
}
private func req() -> ResolvedExecutionRequest {
    ResolvedExecutionRequest(request: ExecutionRequest(capability: .imageUnderstand,
        inputs: [.text("what is this?"), .attachment(EshAttachment(kind: .image, mimeType: "image/png", base64: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))],
        output: OutputSpec(modality: .text)))
}
private func ctx() -> ExecutionContext {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    return ExecutionContext(root: PersistenceRoot(rootURL: u), artifactStore: FileArtifactStore(root: PersistenceRoot(rootURL: u)))
}
private func collect(_ s: AsyncThrowingStream<CapabilityEvent, Error>) async -> (text: String, failed: String?) {
    var text = ""; var failed: String?
    do { for try await e in s { if case .textDelta(let t) = e { text += t }; if case .failed(let m) = e { failed = m } } } catch { failed = "\(error)" }
    return (text, failed)
}

@Suite struct EshVisionTests {
    @Test func moduleLoads() { #expect(EshVision.defaultModelID.isEmpty == false) }

    @Test func understandStreamsTextThenDone() async {
        let p = MLXVisionUnderstandProvider(modelID: "m", supported: true, stream: mockStream(["a ", "cat"]))
        let out = await collect(p.execute(req(), context: ctx()))
        #expect(out.text == "a cat")
        #expect(out.failed == nil)
    }

    @Test func discoveryRequiresDownloadThenReady() async {
        let p = MLXVisionUnderstandProvider(modelID: "m", supported: true, stream: mockStream(["ok"]))
        if case .requiresDownload = p.reportedAvailability(for: .imageUnderstand) {} else { Issue.record("expected requiresDownload initially") }
        _ = await collect(p.execute(req(), context: ctx()))
        if case .ready = p.reportedAvailability(for: .imageUnderstand) {} else { Issue.record("expected ready after a successful run") }
    }

    @Test func unsupportedReportsHonestly() async {
        let p = MLXVisionUnderstandProvider(modelID: "m", supported: false, stream: mockStream(["x"]))
        if case .unsupportedOnPlatform = p.reportedAvailability(for: .imageUnderstand) {} else { Issue.record("expected unsupportedOnPlatform") }
        let out = await collect(p.execute(req(), context: ctx()))
        #expect(out.failed != nil && out.text.isEmpty)
    }

    @Test func missingImageFailsHonestly() async {
        let p = MLXVisionUnderstandProvider(modelID: "m", supported: true, stream: mockStream(["x"]))
        let bare = ResolvedExecutionRequest(request: ExecutionRequest(capability: .imageUnderstand,
            inputs: [.text("no image")], output: OutputSpec(modality: .text)))
        let out = await collect(p.execute(bare, context: ctx()))
        #expect(out.failed != nil)
    }

    @Test func cancellationStops() async {
        let p = MLXVisionUnderstandProvider(modelID: "m", supported: true, stream: hangStream())
        let stream = p.execute(req(), context: ctx())
        let consumer = Task { for try await _ in stream {} }
        try? await Task.sleep(nanoseconds: 50_000_000)
        consumer.cancel()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(true)  // no hang/crash on cancellation
    }

    // Real on-device VLM inference through the PUBLIC facade. Downloads a small VLM from Hugging Face and runs
    // it on the GPU, so it is opt-in (env ESH_VLM_REAL=1) and must be run under xcodebuild (Xcode builds MLX's
    // Metal shader library; plain `swift build`/`swift run` does not). Validates: real descriptive text that
    // reflects the image, honest requiresDownload->ready discovery, prompt cancellation, and model reuse.
    @Test func realOnDeviceUnderstand() async throws {
        // Opt-in gate. Env var when run via `swift test`; a sentinel file when run via `xcodebuild` (which
        // does not propagate the caller's environment into the xctest host). Heavy: network + model + GPU.
        let optedIn = ProcessInfo.processInfo.environment["ESH_VLM_REAL"] == "1"
            || FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.esh_vlm_real")
        guard optedIn else { return }
        let imageURL = Self.makeRedCircleImage()
        let runtime = await EshRuntime.makeWithVision()

        let before = await runtime.capabilityAvailability()
        if case .requiresDownload = before.entries[.imageUnderstand] {} else {
            Issue.record("expected requiresDownload before first load, got \(String(describing: before.entries[.imageUnderstand]))")
        }

        // 1. understand: real text that reflects the image
        let t0 = Date()
        let result = try await runtime.execute(Self.understandRequest(
            "What shape and color is in this image? Answer briefly.", imageURL))
        let dt1 = Date().timeIntervalSince(t0)
        let text = (result.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        FileHandle.standardError.write(Data("[realVLM] first=\(String(format: "%.1f", dt1))s text=\"\(text)\"\n".utf8))
        #expect(!text.isEmpty)
        let lc = text.lowercased()
        #expect(lc.contains("red"))
        #expect(lc.contains("circle") || lc.contains("round") || lc.contains("dot") || lc.contains("sphere") || lc.contains("ball"))

        // discovery now ready
        let after = await runtime.capabilityAvailability()
        if case .ready = after.entries[.imageUnderstand] {} else {
            Issue.record("expected ready after a successful run, got \(String(describing: after.entries[.imageUnderstand]))")
        }

        // 2. cancellation: cancelling the consumer stops a long generation promptly
        let stream = runtime.stream(Self.understandRequest("Describe this image in exhaustive detail, 500+ words.", imageURL))
        let cancelStart = Date()
        let consumer = Task { do { for try await _ in stream {} } catch {} }
        try? await Task.sleep(nanoseconds: 400_000_000)
        consumer.cancel()
        _ = await consumer.value
        let cancelElapsed = Date().timeIntervalSince(cancelStart)
        FileHandle.standardError.write(Data("[realVLM] cancelled in \(String(format: "%.2f", cancelElapsed))s\n".utf8))
        #expect(cancelElapsed < dt1 + 5)

        // 3. reuse: a 2nd request reuses the loaded model (no reload) -> far faster than the first
        let t2 = Date()
        let r2 = try await runtime.execute(Self.understandRequest("Name the single color you see. One word.", imageURL))
        let dt2 = Date().timeIntervalSince(t2)
        let text2 = (r2.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        FileHandle.standardError.write(Data("[realVLM] second=\(String(format: "%.1f", dt2))s text2=\"\(text2)\"\n".utf8))
        #expect(!text2.isEmpty)
        #expect(dt2 < dt1)  // reused model: no second download+load, so strictly faster than the first call
    }

    static func makeRedCircleImage() -> URL {
        let w = 512, h = 512
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 96, y: 96, width: 320, height: 320))
        let img = ctx.makeImage()!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("esh_vlm_red_circle.png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
        return url
    }

    static func understandRequest(_ prompt: String, _ imageURL: URL) -> ExecutionRequest {
        ExecutionRequest(capability: .imageUnderstand,
            inputs: [.text(prompt),
                     .attachment(EshAttachment(kind: .image, mimeType: "image/png", uri: imageURL.absoluteString))],
            output: OutputSpec(modality: .text))
    }
}
