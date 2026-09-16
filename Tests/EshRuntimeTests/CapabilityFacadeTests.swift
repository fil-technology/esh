import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
import EshCore
@testable import EshRuntime

// Tests for the §1/§2/§6 UCMR facade: execute/stream(ExecutionRequest), makeDefault wiring, and
// capabilityAvailability discovery — all without a real Apple FM / MLX / GGUF model.

private struct FacadeMockRuntime: BackendRuntime, @unchecked Sendable {
    let backend: BackendKind
    let modelID: String
    let output: String
    var metrics: Metrics { get async { Metrics(finishReason: "stop") } }
    func prepare(session: ChatSession) async throws {}
    func generate(session: ChatSession, config: GenerationConfig) -> AsyncThrowingStream<String, Error> {
        let out = output
        return AsyncThrowingStream { c in c.yield(out); c.finish() }
    }
    func exportRuntimeCache() async throws -> CacheSnapshot { throw StoreError.invalidManifest("mock") }
    func importRuntimeCache(_ snapshot: CacheSnapshot) async throws { throw StoreError.invalidManifest("mock") }
    func validateCacheCompatibility(_ manifest: CacheManifest) async throws { throw CompatibilityIssue(reason: "mock") }
    func unload() async {}
}

private struct FacadeMockBackend: InferenceBackend, @unchecked Sendable {
    let kind: BackendKind
    let runtimeVersion: String = "mock"
    let output: String
    var ready: Bool = true
    func capabilityReport(for install: ModelInstall) -> BackendCapabilityReport {
        BackendCapabilityReport(backend: kind, runtimeVersion: "mock", ready: ready,
                                supportedFeatures: ready ? [.directInference] : [])
    }
    func loadRuntime(for install: ModelInstall) async throws -> BackendRuntime {
        FacadeMockRuntime(backend: kind, modelID: install.id, output: output)
    }
    func makeCompatibilityChecker(for install: ModelInstall) -> CompatibilityChecking { FacadeMockChecker() }
}

private struct FacadeMockChecker: CompatibilityChecking {
    func validate(manifest: CacheManifest) throws {}
}

private func ggufInstall(_ id: String = "mock-gguf") -> ModelInstall {
    ModelInstall(id: id, spec: ModelSpec(id: id, displayName: id, backend: .gguf,
                                         source: ModelSource(kind: .localPath, reference: id)),
                 installPath: "/tmp/\(id)", sizeBytes: 1, backendFormat: "gguf")
}

/// A runtime whose text path is a deterministic mock returning `output`, with the full portable provider set.
private func makeMockRuntime(output: String, tmp: URL) async -> EshRuntime {
    await EshRuntime.makeDefault(
        backends: [.gguf: FacadeMockBackend(kind: .gguf, output: output)],
        root: PersistenceRoot(rootURL: tmp),
        installProvider: StaticInstallProvider([ggufInstall()])
    )
}

@Suite struct CapabilityFacadeTests {
    private func tmpRoot() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test func bareRuntimeHasNoProvidersWired() async {
        let runtime = EshRuntime()
        let req = ExecutionRequest(capability: .webArtifactGenerate,
                                   inputs: [.text("a page")], output: .webArtifact)
        await #expect(throws: CapabilityError.self) { try await runtime.execute(req) }
    }

    @Test func availabilityReportsHonestStates() async {
        let tmp = tmpRoot(); defer { try? FileManager.default.removeItem(at: tmp) }
        let runtime = await makeMockRuntime(output: "<!DOCTYPE html><html></html>", tmp: tmp)
        let snap = await runtime.capabilityAvailability()

        // OCR is Apple Vision — always ready on-device.
        #expect(snap.isReady(.imageOCR))
        // Text-dependent artifact + language capabilities are ready when a text backend is ready.
        #expect(snap.isReady(.webArtifactGenerate))
        #expect(snap.isReady(.vectorGenerate))
        #expect(snap.isReady(.projectGenerate))
        #expect(snap.isReady(.languageGenerate))
        // A macOS/Python-only generator is never `.ready` on a portable-only runtime.
        #expect(!snap.isReady(.imageGenerate))
        #expect(!snap.isReady(.musicGenerate))
    }

    @Test func availabilityRequiresModelWhenNoBackendReady() async {
        let tmp = tmpRoot(); defer { try? FileManager.default.removeItem(at: tmp) }
        // A wired-but-not-ready backend → text capabilities are not ready (honest transient state), not `.ready`.
        let runtime = await EshRuntime.makeDefault(
            backends: [.gguf: FacadeMockBackend(kind: .gguf, output: "x", ready: false)],
            root: PersistenceRoot(rootURL: tmp),
            installProvider: StaticInstallProvider([ggufInstall()]))
        let snap = await runtime.capabilityAvailability()
        #expect(!snap.isReady(.webArtifactGenerate))
        #expect(snap.isReady(.imageOCR))  // still fine — needs no text model
    }

    @Test func executeWebArtifactProducesArtifact() async throws {
        let tmp = tmpRoot(); defer { try? FileManager.default.removeItem(at: tmp) }
        let html = "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>t</title></head><body><h1>Hello</h1></body></html>"
        let runtime = await makeMockRuntime(output: html, tmp: tmp)
        let req = ExecutionRequest(capability: .webArtifactGenerate,
                                   inputs: [.text("a hello page")], output: .webArtifact)
        let result = try await runtime.execute(req)
        #expect(result.capability == .webArtifactGenerate)
        #expect(result.outputs.contains { $0.kind == .webProject })
    }

    @Test func synthesizeSpeechProducesAudioArtifact() async throws {
        let tmp = tmpRoot(); defer { try? FileManager.default.removeItem(at: tmp) }
        let runtime = await EshRuntime.makeDefault(backends: [:], root: PersistenceRoot(rootURL: tmp),
                                                   installProvider: StaticInstallProvider([]))
        let req = ExecutionRequest(capability: .audioSynthesizeSpeech,
                                   inputs: [.text("Hello from esh.")], output: OutputSpec(modality: .audio))
        let result = try await runtime.execute(req)
        #expect(result.outputs.contains { $0.kind == .audio })
        #expect((result.outputs.first { $0.kind == .audio }?.totalByteSize ?? 0) > 0)
    }

    @Test func availabilityIncludesSpeech() async {
        let tmp = tmpRoot(); defer { try? FileManager.default.removeItem(at: tmp) }
        let runtime = await EshRuntime.makeDefault(backends: [:], root: PersistenceRoot(rootURL: tmp))
        let snap = await runtime.capabilityAvailability()
        #expect(snap.isReady(.audioSynthesizeSpeech))                 // TTS needs no permission
        if case .comingLater = snap.state(for: .audioTranscribe) {    // STT is wired (state depends on auth)
            Issue.record("audio.transcribe should be registered, not comingLater")
        }
    }

    @Test func segmentationIsNativeAndDiscoverable() async {
        let tmp = tmpRoot(); defer { try? FileManager.default.removeItem(at: tmp) }
        let runtime = await EshRuntime.makeDefault(backends: [:], root: PersistenceRoot(rootURL: tmp))
        let snap = await runtime.capabilityAvailability()
        #expect(snap.isReady(.imageSegment))   // native Vision provider — portable, not macOS-only
    }

    @Test func segmentationNoSubjectFailsHonestly() async {
        let tmp = tmpRoot(); defer { try? FileManager.default.removeItem(at: tmp) }
        let runtime = await EshRuntime.makeDefault(backends: [:], root: PersistenceRoot(rootURL: tmp),
                                                   installProvider: StaticInstallProvider([]))
        // 1x1 PNG — no foreground subject → provider must fail honestly, not crash or return garbage.
        let png1x1 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        let req = ExecutionRequest(capability: .imageSegment,
                                   inputs: [.attachment(EshAttachment(kind: .image, mimeType: "image/png", base64: png1x1))],
                                   output: OutputSpec(modality: .image))
        await #expect(throws: CapabilityError.self) { try await runtime.execute(req) }
    }

    @Test func upscaleIsNativeAndDiscoverable() async {
        let tmp = tmpRoot(); defer { try? FileManager.default.removeItem(at: tmp) }
        let runtime = await EshRuntime.makeDefault(backends: [:], root: PersistenceRoot(rootURL: tmp))
        let snap = await runtime.capabilityAvailability()
        #expect(snap.isReady(.imageUpscale))   // native MetalFX/Core Image provider — portable, not macOS-only
    }

    @Test func upscaleProducesLargerImage() async throws {
        let tmp = tmpRoot(); defer { try? FileManager.default.removeItem(at: tmp) }
        let root = PersistenceRoot(rootURL: tmp)
        let runtime = await EshRuntime.makeDefault(backends: [:], root: root,
                                                   installProvider: StaticInstallProvider([]))
        let src = Self.solidPNG(width: 64, height: 64)  // real 64×64 image bytes
        let req = ExecutionRequest(capability: .imageUpscale,
                                   inputs: [.attachment(EshAttachment(kind: .image, mimeType: "image/png", base64: src.base64EncodedString()))],
                                   output: OutputSpec(modality: .image),
                                   options: ExecutionOptions(["scale": .double(2.0)]))
        let result = try await runtime.execute(req)
        #expect(result.outputs.count == 1)
        let artifact = try #require(result.outputs.first)
        let store = FileArtifactStore(root: root)
        let png = try #require(try store.data(id: artifact.id, file: artifact.entrypoint ?? "upscaled.png"))
        let dims = try #require(Self.pngSize(png))
        #expect(dims == CGSize(width: 128, height: 128))   // 64×64 upscaled 2× → 128×128
        FileHandle.standardError.write(Data("[upscale] engine=\(artifact.generatedBy.providerID ?? "?") outBytes=\(png.count)\n".utf8))
    }

    static func solidPNG(width: Int, height: Int) -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let img = ctx.makeImage()!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
        return data as Data
    }

    static func pngSize(_ data: Data) -> CGSize? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return CGSize(width: img.width, height: img.height)
    }

    @Test func streamWebArtifactEmitsArtifactEvent() async throws {
        let tmp = tmpRoot(); defer { try? FileManager.default.removeItem(at: tmp) }
        let html = "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>t</title></head><body><p>hi</p></body></html>"
        let runtime = await makeMockRuntime(output: html, tmp: tmp)
        let req = ExecutionRequest(capability: .webArtifactGenerate,
                                   inputs: [.text("page")], output: .webArtifact)
        var sawArtifact = false
        for try await event in runtime.stream(req) {
            if case .artifactProduced = event { sawArtifact = true }
        }
        #expect(sawArtifact)
    }
}
