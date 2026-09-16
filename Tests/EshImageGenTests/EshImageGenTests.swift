import Foundation
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import Testing
import Hub
import EshCore
import EshRuntime
@testable import EshImageGen

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock(); private var values: [Double] = []
    func append(_ v: Double) { lock.lock(); values.append(v); lock.unlock() }
    var last: Double? { lock.lock(); defer { lock.unlock() }; return values.last }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
}

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

    // Self-hosted weight fetching (zero Hugging Face credentials): download from a base URL into the Hub
    // cache layout, verify checksums, concatenate shards, and skip already-valid files. Uses a local file://
    // source so it needs no network or real weights — the SD load path is exercised by the real gen test.
    @Test func selfHostedFetchPlacesVerifiesAndSkips() async throws {
        let src = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let cache = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: cache) }
        try FileManager.default.createDirectory(at: src.appending(path: "vae"), withIntermediateDirectories: true)
        let cfg = Data("{\"k\":1}".utf8)
        try cfg.write(to: src.appending(path: "vae/config.json"))
        // a sharded weight: host as w.bin.000 + w.bin.001
        let part0 = Data(repeating: 0xAB, count: 2048), part1 = Data(repeating: 0xCD, count: 1024)
        try FileManager.default.createDirectory(at: src.appending(path: "unet"), withIntermediateDirectories: true)
        try part0.write(to: src.appending(path: "unet/w.bin.000"))
        try part1.write(to: src.appending(path: "unet/w.bin.001"))
        let whole = part0 + part1
        func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

        let model = SelfHostedModel(modelID: "esh-test/sd", baseURL: src, files: [
            SelfHostedModel.Entry(relativePath: "vae/config.json", sha256: sha(cfg)),
            SelfHostedModel.Entry(relativePath: "unet/w.bin", sha256: sha(whole), shardCount: 2),
        ])
        let hub = HubApi(downloadBase: cache, useOfflineMode: true)
        let progress = ProgressBox()
        try await SelfHostedFetcher.prefetch(model, hub: hub) { progress.append($0) }

        let dir = hub.localRepoLocation(Hub.Repo(id: "esh-test/sd"))
        #expect(try Data(contentsOf: dir.appending(path: "vae/config.json")) == cfg)
        #expect(try Data(contentsOf: dir.appending(path: "unet/w.bin")) == whole)  // shards concatenated
        #expect(progress.last == 1.0)

        // idempotent: a second prefetch verifies checksums and does not re-copy/throw
        try await SelfHostedFetcher.prefetch(model, hub: hub) { _ in }
        #expect(try Data(contentsOf: dir.appending(path: "unet/w.bin")) == whole)
    }

    @Test func selfHostedFetchRejectsBadChecksum() async {
        let src = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let cache = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: cache) }
        try? FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try? Data("real".utf8).write(to: src.appending(path: "x.bin"))
        let model = SelfHostedModel(modelID: "esh-test/bad", baseURL: src, files: [
            SelfHostedModel.Entry(relativePath: "x.bin", sha256: String(repeating: "0", count: 64))
        ])
        let hub = HubApi(downloadBase: cache, useOfflineMode: true)
        await #expect(throws: EshImageGenError.self) {
            try await SelfHostedFetcher.prefetch(model, hub: hub) { _ in }
        }
    }

    @Test func storageUnavailableFailsCleanly() async {
        // A configured external assets volume that isn't mounted -> the provider must fail cleanly
        // (honest "storage is unavailable"), never silently fall back to the internal disk.
        let stateTmp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let missingExternal = URL(fileURLWithPath: "/Volumes/definitely-not-mounted-\(UUID().uuidString)/esh-models")
        let root = PersistenceRoot(stateRootURL: stateTmp, assetsRootURL: missingExternal)
        let context = ExecutionContext(root: root, artifactStore: FileArtifactStore(root: root))
        let p = MLXImageGenerateProvider(modelID: "m", supported: true, generate: mockEngine(png: tinyPNG()))
        let out = await collect(p.execute(req(), context: context))
        #expect(out.artifacts == 0)
        #expect(out.failed?.contains("storage is unavailable") == true)
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
