import Foundation
import Testing
import EshCore
@testable import EshRuntime
@testable import EshMacCapabilities

// Deterministic tests for the compatibility-runtime state machine + facade integration, using a scriptable
// mock host (no real Python). Covers: discovery states, clean bootstrap, repair, cancellation (no orphan),
// crash recovery, typed errors (no raw traceback), artifact mapping, and the soundfile regression.

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
        let audioEnv = EshManagedPythonHost.bridgeEnvironment(for: .music, root: root)
        #expect(audioEnv["HF_HOME"] == assets.appendingPathComponent("caches/audio-models").path)
        #expect(audioEnv["TMPDIR"] == assets.appendingPathComponent("tmp").path)
        // never the internal state root or the user's ~/.cache
        #expect(audioEnv["HF_HOME"]?.contains(state.path) == false)
        let imageEnv = EshManagedPythonHost.bridgeEnvironment(for: .advancedImageEdit, root: root)
        #expect(imageEnv["HF_HOME"] == assets.appendingPathComponent("caches/image-models").path)
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
