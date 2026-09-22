import Foundation
import Testing
import EshCore
@testable import EshRuntime
@testable import EshMacCapabilities

// Deterministic tests for the compatibility-runtime state machine + facade integration, using a scriptable
// mock host (no real Python). Covers: discovery states, clean bootstrap, repair, cancellation (no orphan),
// crash recovery, typed errors (no raw traceback), artifact mapping, and the soundfile regression.

/// A minimal image.generate provider for registry/gate tests (commercial flag configurable).
private struct MockGenProvider: CapabilityProvider, @unchecked Sendable {
    let descriptor: CapabilityProviderDescriptor
    init(id: String, commercial: Bool) {
        descriptor = CapabilityProviderDescriptor(
            id: id, capabilities: [.imageGenerate], acceptedInputs: [.text], producedOutputs: [.image],
            backend: .mlx, modelFamily: id, streaming: true, structuredOutput: false,
            requiredPrivilege: .artifactOnly, previewMode: .none, commercialUse: commercial)
    }
    func execute(_ r: ResolvedExecutionRequest, context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func unload() async {}
}

private final class MockHost: CompatibilityEngineHost, @unchecked Sendable {
    enum Run { case artifact, throwTyped(CompatibilityError), hang }
    private let lock = NSLock()
    private var _state: CompatibilityEngineState
    private var _run: Run
    private(set) var installCount = 0
    private(set) var repairCount = 0
    private(set) var runCancelled = false
    private(set) var runStarted = false

    init(state: CompatibilityEngineState, run: Run = .artifact) { _state = state; _run = run }
    func state() -> CompatibilityEngineState { lock.lock(); defer { lock.unlock() }; return _state }
    func setState(_ s: CompatibilityEngineState) { lock.lock(); _state = s; lock.unlock() }
    func setRun(_ r: Run) { lock.lock(); _run = r; lock.unlock() }
    private func run() -> Run { lock.lock(); defer { lock.unlock() }; return _run }
    private func markCancelled() { lock.lock(); runCancelled = true; lock.unlock() }
    private func markStarted() { lock.lock(); runStarted = true; lock.unlock() }
    private func bump(install: Bool) { lock.lock(); if install { installCount += 1 } else { repairCount += 1 }; lock.unlock() }

    func inspect(_ manifest: CompatibilityEngineManifest) async -> CompatibilityEngineState { state() }
    func install(_ manifest: CompatibilityEngineManifest, onProgress: @Sendable @escaping (Double) -> Void) async throws {
        bump(install: true); onProgress(0.5); onProgress(1.0); setState(.ready)
    }
    func repair(_ manifest: CompatibilityEngineManifest) async throws { bump(install: false); setState(.ready) }
    func run(_ manifest: CompatibilityEngineManifest, _ request: ResolvedExecutionRequest,
             context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        let behavior = run()
        return AsyncThrowingStream { continuation in
            let task = Task {
                self.markStarted()
                switch behavior {
                case .artifact:
                    continuation.yield(.status("generating"))
                    let art = try? context.artifactStore.save(
                        Artifact(kind: manifest.producedArtifactKind, mimeType: "application/octet-stream",
                                 files: [], entrypoint: "out.bin",
                                 generatedBy: ArtifactProvenance(providerID: "compat", capability: manifest.capabilities.first)),
                        files: ["out.bin": Data([1, 2, 3])])
                    if let art { continuation.yield(.artifactProduced(art)) }
                    continuation.yield(.done(finishReason: "stop")); continuation.finish()
                case .throwTyped(let e):
                    continuation.finish(throwing: e)
                case .hang:
                    do { while true { try Task.checkCancellation(); try await Task.sleep(nanoseconds: 15_000_000) } }
                    catch { self.markCancelled(); continuation.finish(throwing: CancellationError()) }
                }
            }
            continuation.onTermination = { reason in
                if case .cancelled = reason { self.markCancelled() }
                task.cancel()
            }
        }
    }
}

private func musicManifest() -> CompatibilityEngineManifest {
    MacCapabilities.manifests().first { $0.id == .music }!
}
private func ctx(_ tmp: URL) -> ExecutionContext {
    ExecutionContext(root: PersistenceRoot(rootURL: tmp), artifactStore: FileArtifactStore(root: PersistenceRoot(rootURL: tmp)))
}
private func musicRequest() -> ResolvedExecutionRequest {
    ResolvedExecutionRequest(request: ExecutionRequest(capability: .musicGenerate,
        inputs: [.text("uplifting cinematic strings")], output: OutputSpec(modality: .audio)))
}
private func tmpRoot() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
}
/// Run `body` with the given environment overrides applied (nil value = unset), restoring the prior values
/// afterward. Used to exercise env-driven interpreter resolution deterministically.
private func withEnv(_ overrides: [String: String?], _ body: () -> Void) {
    var previous: [String: String?] = [:]
    for (k, v) in overrides {
        previous[k] = ProcessInfo.processInfo.environment[k]
        if let v { setenv(k, v, 1) } else { unsetenv(k) }
    }
    defer { for (k, v) in previous { if let v { setenv(k, v, 1) } else { unsetenv(k) } } }
    body()
}
/// Poll a condition until true or the timeout elapses (deterministic replacement for fixed test sleeps).
private func pollUntil(timeout: TimeInterval, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
}
private func collect(_ stream: AsyncThrowingStream<CapabilityEvent, Error>) async -> (artifacts: [Artifact], failed: String?) {
    var arts: [Artifact] = []; var failed: String?
    do { for try await e in stream {
        if case .artifactProduced(let a) = e { arts.append(a) }
        if case .failed(let m) = e { failed = m }
    } } catch { failed = "\(error)" }
    return (arts, failed)
}

@Suite struct CompatibilityRuntimeTests {
    // These tests inject a scriptable mock host to exercise the compat state machine. They must not be
    // coupled to the CI/dev machine's real free disk, so disable the in-SDK resource preflight here (the
    // preflight itself is covered by dedicated pure-function tests). Set once for the test process.
    init() { setenv("ESH_DISABLE_COMPAT_RESOURCE_PREFLIGHT", "1", 1) }

    @Test func soundfileDeclaredRequiredForMusic() {
        // The regression: music must require soundfile so preflight catches it (not a raw traceback).
        let modules = Set(musicManifest().requiredModules.map { $0.module })
        #expect(modules.contains("soundfile"))
    }

    @Test func discoveryReflectsEngineState() async {
        let host = MockHost(state: .repairRequired(reason: "missing soundfile"))
        let provider = CompatibilityCapabilityProvider(manifest: musicManifest(), host: host, supported: true)
        await provider.refresh()
        if case .repairRequired = provider.reportedAvailability(for: .musicGenerate) {} else {
            Issue.record("expected repairRequired"); return
        }
        host.setState(.ready); await provider.refresh()
        #expect({ if case .ready = provider.reportedAvailability(for: .musicGenerate) { return true }; return false }())
    }

    // MARK: voice cloning (audio.cloneVoice) — XTTS-v2 compat engine (rc.28)

    @Test func voiceCloneManifestIsDeclared() {
        let m = MacCapabilities.manifests().first { $0.id == .voiceClone }
        #expect(m != nil)
        #expect(m?.capabilities == [.audioCloneVoice])
        #expect(m?.acceptedInputs.contains(.audio) == true)   // reference sample
        #expect(m?.acceptedInputs.contains(.text) == true)    // words to speak
        #expect(m?.producedArtifactKind == .audio)
        // coqui-tts lives in the ISOLATED venv (torch<2.9 / transformers<5 can't share the main venv), NOT
        // in the top-level requiredModules that are probed against the shared venv.
        #expect(m?.isolatedRuntime?.modules.contains { $0.module == "TTS" } == true)
        #expect(m?.requiredModules.contains { $0.module == "TTS" } == false)
    }

    @Test func isolatedRuntimesWiredForVoiceCloneAndSoundFX() {
        // rc.30: the two engines whose heavy deps can't share the main MLX venv declare an isolated runtime.
        // Their top-level requiredModules are just the shared bridge deps (probed against the main venv); the
        // conflicting/heavy modules are probed/installed against the dedicated venv instead.
        let manifests = MacCapabilities.manifests()
        let vc = manifests.first { $0.id == .voiceClone }!
        #expect(vc.isolatedRuntime?.dirName == "voiceclone-venv")
        #expect(vc.isolatedRuntime?.envVar == "ESH_VOICECLONE_PYTHON")
        let vcIso = Set(vc.isolatedRuntime?.modules.map { $0.module } ?? [])
        #expect(vcIso.isSuperset(of: ["TTS", "torch", "torchaudio", "transformers", "soundfile"]))
        #expect(vc.requiredModules.contains { $0.module == "torch" } == false)  // not in the shared venv

        let sfx = manifests.first { $0.id == .soundFX }!
        #expect(sfx.isolatedRuntime?.dirName == "audiogen-venv")
        #expect(sfx.isolatedRuntime?.envVar == "ESH_AUDIOGEN_PYTHON")
        #expect(sfx.isolatedRuntime?.modules.contains { $0.module == "mlx_audiocraft" } == true)
        #expect(sfx.requiredModules.contains { $0.module == "mlx_audiocraft" } == false)  // was a false main-venv probe pre-rc.30

        // Engines that DO share the main venv carry no isolated runtime.
        #expect(manifests.first { $0.id == .music }?.isolatedRuntime == nil)
        #expect(manifests.first { $0.id == .diarization }?.isolatedRuntime == nil)
    }

    @Test func voiceCloneProviderExecutesToAudio() async {
        let tmp = tmpRoot(); defer { try? FileManager.default.removeItem(at: tmp) }
        let manifest = MacCapabilities.manifests().first { $0.id == .voiceClone }!
        let host = MockHost(state: .ready, run: .artifact)
        let provider = CompatibilityCapabilityProvider(manifest: manifest, host: host, supported: true)
        let req = ResolvedExecutionRequest(request: ExecutionRequest(
            capability: .audioCloneVoice,
            inputs: [.text("hello in my voice"),
                     .init(payload: .attachment(EshAttachment(kind: .audio, uri: "file:///tmp/ref.wav")), role: "reference")],
            output: OutputSpec(modality: .audio)))
        let out = await collect(provider.execute(req, context: ctx(tmp)))
        #expect(out.failed == nil)
        #expect(out.artifacts.contains { $0.kind == .audio })
    }

    @Test func bridgeRequestMapsVoiceCloneInputs() throws {
        let req = ResolvedExecutionRequest(request: ExecutionRequest(
            capability: .audioCloneVoice,
            inputs: [.text("clone this line"),
                     .init(payload: .attachment(EshAttachment(kind: .audio, uri: "file:///tmp/voices/ref.wav")), role: "reference")],
            output: OutputSpec(modality: .audio),
            options: ExecutionOptions(["language": .string("es")])))
        let data = try EshManagedPythonHost.bridgeRequest(.voiceClone, req, outputPath: "/tmp/out.wav",
                                                          root: PersistenceRoot(rootURL: tmpRoot()))
        let dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(dict["text"] as? String == "clone this line")
        #expect(dict["referencePath"] as? String == "/tmp/voices/ref.wav")   // file:// resolved to a path
        #expect(dict["language"] as? String == "es")
        #expect(dict["outputPath"] as? String == "/tmp/out.wav")
        #expect((dict["hfCache"] as? String)?.isEmpty == false)
    }

    // MARK: Qwen-Image-2.1 (image.generate + image.restyle via MFLUX, NON-COMMERCIAL) — rc.31

    @Test func qwenImage21ManifestIsGenerateAndRestyleOnly() {
        let m = MacCapabilities.manifests().first { $0.id == .qwenImage21 }
        #expect(m != nil)
        // Only what the MFLUX port actually implements: txt2img + img2img restyle. NOT instruction edit.
        #expect(m?.capabilities == [.imageGenerate, .imageRestyle])
        #expect(m?.capabilities.contains(.imageEdit) == false)
        #expect(m?.acceptedInputs.contains(.text) == true)
        #expect(m?.acceptedInputs.contains(.image) == true)   // img2img restyle source
        #expect(m?.producedArtifactKind == .image)
        // Truthful non-commercial license + resource profile reflecting the ~46 GB / 17.5 GB-resident reality.
        #expect(m?.licenseIdentifier == "LicenseRef-Qwen-Research")
        #expect(m?.commercialUse == false)
        #expect(m?.resourceProfile != nil)
        #expect((m?.resourceProfile?.estimatedPeakMemoryGB ?? 0) >= 24)   // never a "fits comfortably" claim
        #expect(m?.requiredModules.contains { $0.pipPackage.contains("mflux") } == true)
    }

    @Test func qwenImage21ProviderDescriptorIsNonCommercialAndPinnable() {
        let manifest = MacCapabilities.manifests().first { $0.id == .qwenImage21 }!
        let provider = CompatibilityCapabilityProvider(manifest: manifest, host: MockHost(state: .ready), supported: true)
        let d = provider.descriptor
        #expect(d.commercialUse == false)
        #expect(d.modelFamily == "qwen-image-2.1")            // pinnable id
        #expect(d.resourceProfile?.estimatedPeakMemoryGB ?? 0 >= 24)
        #expect(d.capabilities.contains(.imageGenerate) && d.capabilities.contains(.imageRestyle))
    }

    @Test func nonCommercialModelIsPinOnlyNeverAutoDefault() {
        // The commercial gate: a non-commercial provider must never be offered by Auto (no pin), but must be
        // reachable when explicitly pinned — so it can't silently become a commercial-production default.
        var reg = CapabilityRegistry()
        let qwen = MacCapabilities.manifests().first { $0.id == .qwenImage21 }!
        reg.register(CompatibilityCapabilityProvider(manifest: qwen, host: MockHost(state: .ready, run: .artifact), supported: true))
        reg.register(MockGenProvider(id: "z-image", commercial: true))   // a commercial-safe image.generate default

        let auto = ExecutionRequest(capability: .imageGenerate, inputs: [.text("a tiger")],
                                    output: OutputSpec(modality: .image), model: nil)
        let autoIDs = reg.candidates(for: auto).map { $0.descriptor.id }
        #expect(autoIDs.contains("z-image"))                                  // commercial default offered
        #expect(autoIDs.contains("compat-qwen-image-2.1") == false)          // NON-commercial excluded from Auto

        let pinned = ExecutionRequest(capability: .imageGenerate, inputs: [.text("a tiger")],
                                      output: OutputSpec(modality: .image), model: "qwen-image-2.1")
        let pinnedIDs = reg.candidates(for: pinned).map { $0.descriptor.id }
        #expect(pinnedIDs == ["compat-qwen-image-2.1"])                       // explicit pin reaches it
    }

    @Test func bridgeCommandForQwenImage21() {
        let (cmd, ext, kind) = EshManagedPythonHost.bridgeCommand(for: .qwenImage21)
        #expect(cmd == "image-generate-qwen21")
        #expect(ext == "png")
        #expect(kind == .image)
    }

    @Test func bridgeRequestMapsQwenImage21Generate() throws {
        let req = ResolvedExecutionRequest(request: ExecutionRequest(
            capability: .imageGenerate, inputs: [.text("a majestic tiger, photorealistic")],
            output: OutputSpec(modality: .image),
            options: ExecutionOptions(["steps": .int(30), "seed": .int(42), "width": .int(1024),
                                       "height": .int(768), "quantize": .int(4)])))
        let data = try EshManagedPythonHost.bridgeRequest(.qwenImage21, req, outputPath: "/tmp/q.png",
                                                          root: PersistenceRoot(rootURL: tmpRoot()))
        let dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(dict["prompt"] as? String == "a majestic tiger, photorealistic")
        #expect(dict["steps"] as? Int == 30)
        #expect(dict["seed"] as? Int == 42)
        #expect(dict["width"] as? Int == 1024)
        #expect(dict["quantize"] as? Int == 4)
        #expect(dict["imagePath"] == nil)                  // no image → txt2img (generate)
        #expect((dict["hfCache"] as? String)?.contains("image-models") == true)
    }

    @Test func bridgeRequestMapsQwenImage21RestyleImg2Img() throws {
        let req = ResolvedExecutionRequest(request: ExecutionRequest(
            capability: .imageRestyle,
            inputs: [.text("3d animation style"),
                     .init(payload: .attachment(EshAttachment(kind: .image, uri: "file:///tmp/couple.png")), role: "source")],
            output: OutputSpec(modality: .image),
            options: ExecutionOptions(["imageStrength": .double(0.6)])))
        let data = try EshManagedPythonHost.bridgeRequest(.qwenImage21, req, outputPath: "/tmp/q.png",
                                                          root: PersistenceRoot(rootURL: tmpRoot()))
        let dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(dict["imagePath"] as? String == "/tmp/couple.png")   // image present → img2img restyle
        #expect(dict["imageStrength"] as? Double == 0.6)
        #expect(dict["steps"] as? Int == 40)                          // qwen-2.1 default when unspecified
    }

    @Test func bridgeRequestQwenImage21RejectsEmptyPrompt() {
        let req = ResolvedExecutionRequest(request: ExecutionRequest(
            capability: .imageGenerate, inputs: [], output: OutputSpec(modality: .image)))
        #expect(throws: CompatibilityError.self) {
            _ = try EshManagedPythonHost.bridgeRequest(.qwenImage21, req, outputPath: "/tmp/q.png",
                                                       root: PersistenceRoot(rootURL: tmpRoot()))
        }
    }

    @Test func bridgeRequestVoiceCloneRejectsMissingReference() {
        let req = ResolvedExecutionRequest(request: ExecutionRequest(
            capability: .audioCloneVoice, inputs: [.text("no reference here")],
            output: OutputSpec(modality: .audio)))
        #expect(throws: CompatibilityError.self) {
            _ = try EshManagedPythonHost.bridgeRequest(.voiceClone, req, outputPath: "/tmp/out.wav",
                                                       root: PersistenceRoot(rootURL: tmpRoot()))
        }
    }

    @Test func cleanBootstrapInstallsThenProduces() async {
        let tmp = tmpRoot(); defer { try? FileManager.default.removeItem(at: tmp) }
        let host = MockHost(state: .notInstalled, run: .artifact)
        let provider = CompatibilityCapabilityProvider(manifest: musicManifest(), host: host, supported: true)
        let out = await collect(provider.execute(musicRequest(), context: ctx(tmp)))
        #expect(host.installCount == 1)
        #expect(out.failed == nil)
        #expect(out.artifacts.contains { $0.kind == .audio })
    }

    @Test func repairRequiredIsRepairedThenProduces() async {
        let tmp = tmpRoot(); defer { try? FileManager.default.removeItem(at: tmp) }
        let host = MockHost(state: .repairRequired(reason: "missing soundfile"), run: .artifact)
        let provider = CompatibilityCapabilityProvider(manifest: musicManifest(), host: host, supported: true)
        let out = await collect(provider.execute(musicRequest(), context: ctx(tmp)))
        #expect(host.repairCount == 1)
        #expect(out.artifacts.contains { $0.kind == .audio })
    }

    @Test func cancellationStopsRunNoOrphan() async {
        let tmp = tmpRoot(); defer { try? FileManager.default.removeItem(at: tmp) }
        let host = MockHost(state: .ready, run: .hang)
        let provider = CompatibilityCapabilityProvider(manifest: musicManifest(), host: host, supported: true)
        let stream = provider.execute(musicRequest(), context: ctx(tmp))
        let consumer = Task { for try await _ in stream {} }
        // Deterministic instead of a fixed sleep: wait until the host run has actually started, cancel, then
        // wait until cancellation has propagated — poll with a timeout so build-machine load can't race it.
        await pollUntil(timeout: 3) { host.runStarted }
        #expect(host.runStarted)
        consumer.cancel()
        await pollUntil(timeout: 3) { host.runCancelled }
        #expect(host.runCancelled)   // cancellation propagated to the host run; no orphan left running
    }

    @Test func crashYieldsTypedErrorThenRecovers() async {
        let tmp = tmpRoot(); defer { try? FileManager.default.removeItem(at: tmp) }
        let host = MockHost(state: .ready, run: .throwTyped(.executionFailed(reason: "engine crashed")))
        let provider = CompatibilityCapabilityProvider(manifest: musicManifest(), host: host, supported: true)
        let first = await collect(provider.execute(musicRequest(), context: ctx(tmp)))
        #expect(first.failed != nil)
        #expect(first.failed?.contains("Traceback") == false)   // typed, not a raw traceback
        // Recovery: a subsequent request succeeds — the runtime is not permanently poisoned.
        host.setRun(.artifact)
        let second = await collect(provider.execute(musicRequest(), context: ctx(tmp)))
        #expect(second.artifacts.contains { $0.kind == .audio })
    }

    @Test func unsupportedPlatformReportsHonestly() async {
        let tmp = tmpRoot(); defer { try? FileManager.default.removeItem(at: tmp) }
        let host = MockHost(state: .ready, run: .artifact)
        let provider = CompatibilityCapabilityProvider(manifest: musicManifest(), host: host, supported: false)
        if case .unsupportedOnPlatform = provider.reportedAvailability(for: .musicGenerate) {} else {
            Issue.record("expected unsupportedOnPlatform when unsupported")
        }
        let out = await collect(provider.execute(musicRequest(), context: ctx(tmp)))
        #expect(out.failed != nil)
        #expect(out.artifacts.isEmpty)
    }

    #if os(macOS)
    @Test func mapperTurnsRealSoundfileTracebackIntoRepair() {
        // The exact failure from the screenshot must become a typed, clean repairRequired — not a traceback.
        let stderr = """
        Loading weights: 100%|██████████| 611/611 [00:00<00:00, 3244.24it/s]
        Traceback (most recent call last):
          File ".../mlx_vlm_bridge.py", line 2517, in audio_or_music_generate
            import soundfile as sf
        ModuleNotFoundError: No module named 'soundfile'
        """
        let state = EshManagedPythonHost.map(stderr: stderr, fallbackReason: "unknown")
        guard case .repairRequired(let reason) = state else { Issue.record("expected repairRequired"); return }
        #expect(reason.contains("soundfile"))
        #expect(reason.contains("Traceback") == false)
    }

    @Test func realProbeDetectsMissingModule() {
        let candidates = ["/opt/homebrew/bin/python3", "/usr/bin/python3"]
        guard let py = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
        let (code, stderr) = EshManagedPythonHost.runProbe(python: py, module: "definitely_not_a_real_module_xyz_123")
        #expect(code != 0)
        if case .repairRequired = EshManagedPythonHost.map(stderr: stderr, fallbackReason: "missing") {} else {
            Issue.record("expected repairRequired from a real missing-module probe")
        }
    }
    #endif

    #if os(macOS)
    // The compatibility bridge must route ALL heavy Hugging Face / model / temp I/O to the configured
    // assets volume (external SSD), never the internal disk — via the per-request paths and the subprocess
    // environment. These assert both, using a PersistenceRoot whose assets root differs from its state root.
    @Test func bridgeRequestRoutesHeavyPathsToAssetsRoot() throws {
        let state = tmpRoot(); let assets = tmpRoot()
        defer { try? FileManager.default.removeItem(at: state); try? FileManager.default.removeItem(at: assets) }
        let root = PersistenceRoot(stateRootURL: state, assetsRootURL: assets)
        func json(_ id: CompatibilityEngineID, _ req: ResolvedExecutionRequest) throws -> [String: Any] {
            let data = try EshManagedPythonHost.bridgeRequest(id, req, outputPath: "/x/out.bin", root: root)
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        // music/SFX -> audio cache on the assets volume
        let music = try json(.music, ResolvedExecutionRequest(request: ExecutionRequest(
            capability: .musicGenerate, inputs: [.text("calm piano")], output: OutputSpec(modality: .audio))))
        #expect((music["hfCache"] as? String) == assets.appendingPathComponent("caches/audio-models").path)
        // image edit -> image cache on the assets volume + model paths
        let edit = try json(.advancedImageEdit, ResolvedExecutionRequest(request: ExecutionRequest(
            capability: .imageEdit,
            inputs: [.text("make it snowy"), .attachment(EshAttachment(kind: .image, mimeType: "image/png", uri: "file:///t.png"))],
            output: OutputSpec(modality: .image))))
        #expect((edit["hfCache"] as? String) == assets.appendingPathComponent("caches/image-models").path)
        // diarization -> sherpa-onnx models on the assets volume
        let diar = try json(.diarization, ResolvedExecutionRequest(request: ExecutionRequest(
            capability: .audioDiarize,
            inputs: [.attachment(EshAttachment(kind: .audio, mimeType: "audio/wav", uri: "file:///a.wav"))],
            output: OutputSpec(modality: .json))))
        #expect((diar["segModel"] as? String) == assets.appendingPathComponent("audio/diarization-models/segmentation.onnx").path)
        #expect((diar["embModel"] as? String) == assets.appendingPathComponent("audio/diarization-models/embedding.onnx").path)
    }

    @Test func stripsAppleDoubleFilesFromVenv() throws {
        // exFAT external volumes accumulate macOS AppleDouble `._*` sidecars that break Python package
        // directory scans (transformers). The managed install path strips them; real `.py` files are kept.
        let venv = tmpRoot(); defer { try? FileManager.default.removeItem(at: venv) }
        let site = venv.appendingPathComponent("lib/python3.11/site-packages/transformers/models", isDirectory: true)
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        try Data("real source".utf8).write(to: site.appendingPathComponent("__init__.py"))
        try Data([0xb0, 0x00, 0x01]).write(to: site.appendingPathComponent("._" + "__init__.py"))  // binary AppleDouble
        try Data([0xb0]).write(to: site.appendingPathComponent("._albert"))
        let removed = EshManagedPythonHost.stripAppleDoubleFiles(inVenvFor: venv.appendingPathComponent("bin/python").path)
        #expect(removed == 2)
        #expect(FileManager.default.fileExists(atPath: site.appendingPathComponent("__init__.py").path))
        #expect(!FileManager.default.fileExists(atPath: site.appendingPathComponent("._" + "__init__.py").path))
        // Idempotent: a second pass removes nothing and does not throw.
        #expect(EshManagedPythonHost.stripAppleDoubleFiles(inVenvFor: venv.appendingPathComponent("bin/python").path) == 0)
    }

    @Test func insufficientResourcesPreflightIsHonestAndSizeScaled() {
        let audiogen = CompatibilityEngineManifest(
            id: .soundFX, version: "1", capabilities: [.audioGenerate],
            acceptedInputs: [.text], producedOutputs: [.audio], producedArtifactKind: .audio,
            runtimeVersion: "esh-compat-1", minimumOS: "macOS 14", requiredModules: [],
            modelAssets: [.init(id: "audiogen", displayName: "AudioGen", approxBytes: 1_600_000_000)])
        let flux = CompatibilityEngineManifest(
            id: .advancedImageEdit, version: "1", capabilities: [.imageEdit],
            acceptedInputs: [.image, .text], producedOutputs: [.image], producedArtifactKind: .image,
            runtimeVersion: "esh-compat-1", minimumOS: "macOS 14", requiredModules: [],
            modelAssets: [.init(id: "flux", displayName: "FLUX", approxBytes: 8_600_000_000)])
        let gib: Int64 = 1_073_741_824
        // Unknown free space never blocks (honesty over false negatives).
        #expect(CompatibilityCapabilityProvider.insufficientResourceReason(internalFreeBytes: nil, manifest: audiogen) == nil)
        // Below the 8 GiB base floor → blocked, with an honest reason naming the engine.
        let low = CompatibilityCapabilityProvider.insufficientResourceReason(internalFreeBytes: 3 * gib, manifest: audiogen)
        #expect(low != nil)
        #expect(low?.contains("sound-fx") == true)
        // Comfortable headroom for the small model → allowed.
        #expect(CompatibilityCapabilityProvider.insufficientResourceReason(internalFreeBytes: 12 * gib, manifest: audiogen) == nil)
        // Heavier model scales the requirement up (2× 8.6 GiB ≈ 17.2 GiB): 12 GiB is fine for audiogen but not flux.
        #expect(CompatibilityCapabilityProvider.insufficientResourceReason(internalFreeBytes: 12 * gib, manifest: flux) != nil)
        #expect(CompatibilityCapabilityProvider.insufficientResourceReason(internalFreeBytes: 20 * gib, manifest: flux) == nil)
    }

    @Test func insufficientResourcesMapsToTemporarilyUnavailable() {
        let state = CompatibilityEngineState.insufficientResources(reason: "only 3.0 GiB free")
        guard case .temporarilyUnavailable(let reason) = state.availability else {
            Issue.record("expected .temporarilyUnavailable"); return
        }
        #expect(reason.contains("3.0 GiB"))
    }

    // Real end-to-end SFX generation through the esh-managed AudioGen runtime on the configured storage
    // volume. Multi-GB and slow, so it is OFF by default and only runs when ESH_RUN_COMPAT_INTEGRATION=1.
    // Provision first with scripts/setup-audio-runtime.sh, and launch behind the disk/swap guard:
    //   scripts/compat-preflight.sh env ESH_RUN_COMPAT_INTEGRATION=1 \
    //     swift test --filter integrationSFXGeneratesAudioOnManagedRuntime
    @Test func integrationSFXGeneratesAudioOnManagedRuntime() async throws {
        guard ProcessInfo.processInfo.environment["ESH_RUN_COMPAT_INTEGRATION"] == "1" else { return }
        let host = EshManagedPythonHost(pythonPath: nil, bridgeScriptsDir: nil)
        let runtime = await EshRuntime.makeWithMacCapabilities(host: host)
        let req = ExecutionRequest(capability: .audioGenerate,
                                   inputs: [.text("rain on a window with distant thunder")],
                                   output: OutputSpec(modality: .audio, format: "audio/wav"))
        let result = try await runtime.execute(req)
        let audio = result.outputs.first { $0.kind == .audio }
        #expect(audio != nil, "audio.generate produced no audio artifact (provision with scripts/setup-audio-runtime.sh)")
        #expect((audio?.totalByteSize ?? 0) > 0, "audio artifact is empty")
    }

    @Test func bridgeEnvironmentKeepsHeavyIOoffInternalDisk() {
        let state = tmpRoot(); let assets = tmpRoot()
        defer { try? FileManager.default.removeItem(at: state); try? FileManager.default.removeItem(at: assets) }
        let root = PersistenceRoot(stateRootURL: state, assetsRootURL: assets)
        let host = EshManagedPythonHost()
        let manifests = MacCapabilities.manifests()
        let music = manifests.first { $0.id == .music }!
        let imageEdit = manifests.first { $0.id == .advancedImageEdit }!
        let audioEnv = host.bridgeEnvironment(for: music, root: root)
        #expect(audioEnv["HF_HOME"] == assets.appendingPathComponent("caches/audio-models").path)
        #expect(audioEnv["TMPDIR"] == assets.appendingPathComponent("tmp").path)
        // never the internal state root or the user's ~/.cache
        #expect(audioEnv["HF_HOME"]?.contains(state.path) == false)
        let imageEnv = host.bridgeEnvironment(for: imageEdit, root: root)
        #expect(imageEnv["HF_HOME"] == assets.appendingPathComponent("caches/image-models").path)

        // Engines with no isolated runtime never set an isolated interpreter env var.
        #expect(audioEnv["ESH_VOICECLONE_PYTHON"] == nil)
        #expect(audioEnv["ESH_AUDIOGEN_PYTHON"] == nil)
    }

    @Test func bridgeEnvironmentHonorsIsolatedInterpreterOverride() {
        // The bridge locates an isolated engine venv via its env var; an ambient override to a usable
        // interpreter (an externally-provisioned venv) must be honored so run() points the worker at it.
        let state = tmpRoot(); let assets = tmpRoot()
        defer { try? FileManager.default.removeItem(at: state); try? FileManager.default.removeItem(at: assets) }
        let root = PersistenceRoot(stateRootURL: state, assetsRootURL: assets)
        let host = EshManagedPythonHost()
        let voiceClone = MacCapabilities.manifests().first { $0.id == .voiceClone }!

        // No isolated venv anywhere → the env var is left unset (honest: not yet provisioned).
        withEnv(["ESH_VOICECLONE_PYTHON": nil]) {
            #expect(host.bridgeEnvironment(for: voiceClone, root: root)["ESH_VOICECLONE_PYTHON"] == nil)
        }
        // A usable interpreter injected via the override is adopted verbatim.
        let sysPython = "/usr/bin/python3"
        if FileManager.default.isExecutableFile(atPath: sysPython) {
            withEnv(["ESH_VOICECLONE_PYTHON": sysPython]) {
                #expect(host.bridgeEnvironment(for: voiceClone, root: root)["ESH_VOICECLONE_PYTHON"] == sysPython)
            }
        }
    }
    #endif

    @Test func discoveryThroughFacade() async {
        let tmp = tmpRoot(); defer { try? FileManager.default.removeItem(at: tmp) }
        let host = MockHost(state: .ready, run: .artifact)
        let runtime = await EshRuntime.makeDefault(
            backends: [:], root: PersistenceRoot(rootURL: tmp),
            additionalProviders: MacCapabilities.providers(host: host))
        for p in MacCapabilities.providers(host: host) { _ = p }  // touch
        let snap = await runtime.capabilityAvailability()
        // music is registered via the compat provider; state reported (not comingLater/unsupported by default on macOS).
        let state = snap.state(for: .musicGenerate)
        if case .comingLater = state { Issue.record("music should be exposed via compat provider, got comingLater") }
    }
}
