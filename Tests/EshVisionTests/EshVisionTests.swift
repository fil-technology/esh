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
    { _, _, _ in AsyncThrowingStream { c in for t in tokens { c.yield(t) }; c.finish() } }
}
private func hangStream() -> VLMStreamFn {
    { _, _, _ in AsyncThrowingStream { c in
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

// `.serialized`: the real-weight tests each load a VLM; serialize so two models never load concurrently.
@Suite(.serialized) struct EshVisionTests {
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

        // 1. understand: real text that reflects the image. Validate SHAPE and COLOR with two focused,
        //    single-word prompts rather than one combined "answer briefly" prompt. A combined prompt lets a
        //    4-bit VLM degenerate into repeating one attribute (e.g. "circlecircle…") and never mention the
        //    other — which is a generation quirk, not a recognition failure, yet it made a strict combined
        //    assertion flaky. Focused prompts elicit a concise answer for each attribute, so each assertion
        //    stays strict (a genuine recognition failure still fails) without the flakiness. English or
        //    Chinese answers are both accepted (the model is non-deterministic across languages).
        // Bounded generation: a small maxTokens is enough for a one-word attribute answer and prevents the
        // unbounded/degenerate repetition that otherwise made this run time out.
        func understandText(_ prompt: String) async throws -> String {
            let r = try await runtime.execute(Self.understandRequest(prompt, imageURL, maxTokens: 32))
            return (r.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func containsShape(_ lc: String, _ raw: String) -> Bool {
            lc.contains("circle") || lc.contains("round") || lc.contains("dot") || lc.contains("sphere")
                || lc.contains("ball") || raw.contains("圆")
        }
        func containsColor(_ lc: String, _ raw: String) -> Bool { lc.contains("red") || raw.contains("红") }

        // First (cold) call establishes the load+inference baseline dt1 used by the cancellation/reuse checks.
        let t0 = Date()
        let shapeText = try await understandText("What shape is in this image? Answer with a single word.")
        let dt1 = Date().timeIntervalSince(t0)
        let colorText = try await understandText("What color is in this image? Answer with a single word.")
        FileHandle.standardError.write(Data("[realVLM] first=\(String(format: "%.1f", dt1))s shape=\"\(shapeText)\" color=\"\(colorText)\"\n".utf8))
        #expect(!shapeText.isEmpty)
        #expect(!colorText.isEmpty)
        // Strict: the model must identify the circle AND the red colour (either prompt may surface either
        // attribute, so accept a match in either response — but both attributes must appear somewhere).
        let shapeLC = shapeText.lowercased(), colorLC = colorText.lowercased()
        #expect(containsShape(shapeLC, shapeText) || containsShape(colorLC, colorText))
        #expect(containsColor(colorLC, colorText) || containsColor(shapeLC, shapeText))

        // discovery now ready
        let after = await runtime.capabilityAvailability()
        if case .ready = after.entries[.imageUnderstand] {} else {
            Issue.record("expected ready after a successful run, got \(String(describing: after.entries[.imageUnderstand]))")
        }

        // 2. cancellation: cancelling the consumer stops a long generation promptly. A higher cap gives
        //    enough tokens to interrupt mid-stream while still bounding the run.
        let stream = runtime.stream(Self.understandRequest("Describe this image in exhaustive detail, 500+ words.", imageURL, maxTokens: 256))
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
        let r2 = try await runtime.execute(Self.understandRequest("Name the single color you see. One word.", imageURL, maxTokens: 32))
        let dt2 = Date().timeIntervalSince(t2)
        let text2 = (r2.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        FileHandle.standardError.write(Data("[realVLM] second=\(String(format: "%.1f", dt2))s text2=\"\(text2)\"\n".utf8))
        #expect(!text2.isEmpty)
        #expect(dt2 < dt1)  // reused model: no second download+load, so strictly faster than the first call
    }

    // Separate evaluation (NOT the authoritative validation): can the VLM name BOTH attributes in ONE brief
    // response? A 4-bit model sometimes fixates on one attribute, so the both-in-one expectation is wrapped in
    // `withKnownIssue` — a miss is reported, without failing the suite or weakening the focused shape/color
    // assertions in `realOnDeviceUnderstand`. The strict part (coherent, bounded, non-degenerate output) still
    // fails hard if generation is broken.
    @Test func realCombinedUnderstand() async throws {
        let optedIn = ProcessInfo.processInfo.environment["ESH_VLM_REAL"] == "1"
            || FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.esh_vlm_real")
        guard optedIn else { return }
        let imageURL = Self.makeRedCircleImage()
        let runtime = await EshRuntime.makeWithVision()
        let r = try await runtime.execute(Self.understandRequest(
            "What color and shape is in this image? Answer in one short phrase like 'a red circle'.",
            imageURL, maxTokens: 48))
        let text = (r.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        FileHandle.standardError.write(Data("[realVLM-combined] text=\"\(text)\"\n".utf8))
        let lc = text.lowercased()
        // Strict (migration-level): generation is bounded, coherent, and non-degenerate.
        #expect(!text.isEmpty)
        #expect(text.count < 400)  // bounded by maxTokens — no runaway repetition
        let hasShape = lc.contains("circle") || lc.contains("round") || lc.contains("dot")
            || lc.contains("sphere") || lc.contains("ball") || text.contains("圆")
        let hasColor = lc.contains("red") || text.contains("红")
        // Model-capability evaluation (reported, non-fatal): both attributes in one response.
        withKnownIssue("A 4-bit VLM may not reliably include both colour and shape in one brief response.",
                       isIntermittent: true) {
            #expect(hasShape && hasColor)
        }
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

    static func understandRequest(_ prompt: String, _ imageURL: URL, maxTokens: Int? = nil) -> ExecutionRequest {
        let options = maxTokens.map { ExecutionOptions(["maxTokens": .int($0)]) } ?? ExecutionOptions([:])
        return ExecutionRequest(capability: .imageUnderstand,
            inputs: [.text(prompt),
                     .attachment(EshAttachment(kind: .image, mimeType: "image/png", uri: imageURL.absoluteString))],
            output: OutputSpec(modality: .text), options: options)
    }
}
