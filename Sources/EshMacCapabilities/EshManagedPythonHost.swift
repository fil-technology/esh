import Foundation
import EshCore
import EshRuntime

#if os(macOS)

// The concrete esh-owned macOS host: manages a Python runtime esh controls (never the consumer's), probes
// declared modules for preflight, repairs missing dependencies via pip, and supervises the model-execution
// bridge subprocess. A consumer never sees Python — only states/events/artifacts through the provider.
//
// Scope: esh owns the managed Python runtime end-to-end. When no `pythonPath` is injected (the consumer
// contract — `EshManagedPythonHost()`), the host adopts or provisions a relocatable esh-controlled
// interpreter (python-build-standalone, no Homebrew) under the configured assets root via
// `ManagedPythonRuntime`, creates the venv, installs/repairs engine deps, and resolves the shipped bridge
// scripts from `Bundle.module` — the consumer supplies nothing. `pythonPath`/`bridgeScriptsDir` remain
// injectable so the CLI and tests can pin a specific interpreter/bridge and this host stays real + testable.
public final class EshManagedPythonHost: CompatibilityEngineHost, @unchecked Sendable {
    private let pythonPath: String?
    private let bridgeScriptsDir: String?     // dir containing mlx_vlm_bridge.py (shipped by esh, not the consumer)
    private let explicitRoot: PersistenceRoot?

    /// Managed default: esh owns interpreter + bridge provisioning. A consumer uses exactly this.
    public convenience init() { self.init(pythonPath: nil, bridgeScriptsDir: nil, root: nil) }

    public init(pythonPath: String?, bridgeScriptsDir: String?, root: PersistenceRoot? = nil) {
        self.pythonPath = pythonPath
        self.bridgeScriptsDir = bridgeScriptsDir
        self.explicitRoot = root
    }

    // MARK: - Managed runtime + bridge resolution

    /// The persistence root that locates the managed runtime. Falls back to the process-wide default, which
    /// honors the public storage lever (`ESH_ASSETS_HOME` / `~/.esh/storage.json`) — so heavy runtime/assets
    /// land on the configured external volume without the consumer passing anything.
    private func resolvedRoot() -> PersistenceRoot { explicitRoot ?? .default() }

    /// An interpreter esh can use right now WITHOUT provisioning: an injected path, else an already-adopted
    /// managed venv. Returns nil when nothing usable exists yet (→ honest `.requiresDownload`).
    private func adoptablePython(root: PersistenceRoot) -> String? {
        if let pythonPath, FileManager.default.isExecutableFile(atPath: pythonPath) { return pythonPath }
        let managed = ManagedPythonRuntime(root: root).venvPythonPath
        return ManagedPythonRuntime.isUsable(managed) ? managed : nil
    }

    /// An interpreter esh can use, provisioning the managed runtime if necessary (install/repair path).
    private func ensurePython(root: PersistenceRoot, onProgress: @Sendable @escaping (Double) -> Void) async throws -> String {
        if let pythonPath, FileManager.default.isExecutableFile(atPath: pythonPath) { onProgress(1.0); return pythonPath }
        return try await ManagedPythonRuntime(root: root).provisionedPython(onProgress: onProgress)
    }

    // MARK: - Isolated per-engine venvs (voice-clone, AudioGen)
    //
    // A few engines can't share the main MLX venv (conflicting pins would destabilize it), so their heavy deps
    // live in a dedicated venv under the managed audio-assets root. The env override the bridge reads takes
    // precedence, so an externally-provisioned isolated venv (e.g. from scripts/setup-audio-runtime.sh) is
    // honored too. inspect/install/repair route to whichever venv actually holds the engine's runtime.

    /// The esh-managed venv directory for an isolated engine. It lives on the INTERNAL APFS state root
    /// alongside the main managed venv — NOT the external assets volume, which is often exFAT and poisons pip's
    /// metadata scan with AppleDouble `._*` sidecars (a `python -m venv` + pip there fails with a
    /// `UnicodeDecodeError`). Only heavy model weights/caches go to the assets volume (via `HF_HOME` etc.).
    private func isolatedVenvURL(_ iso: IsolatedRuntime, root: PersistenceRoot) -> URL {
        root.stateRootURL.appendingPathComponent("runtime/isolated", isDirectory: true)
            .appendingPathComponent(iso.dirName, isDirectory: true)
    }

    /// The esh-managed location of an isolated engine venv's interpreter (on the internal state root).
    private func isolatedPythonPath(_ iso: IsolatedRuntime, root: PersistenceRoot) -> String {
        isolatedVenvURL(iso, root: root).appendingPathComponent("bin/python3").path
    }

    /// An isolated interpreter esh can use right now WITHOUT provisioning: an env-injected path (bridge
    /// override / externally-provisioned venv), else the esh-managed isolated venv. `nil` when neither exists.
    private func adoptableIsolatedPython(_ iso: IsolatedRuntime, root: PersistenceRoot) -> String? {
        if let injected = ProcessInfo.processInfo.environment[iso.envVar],
           ManagedPythonRuntime.isUsable(injected) { return injected }
        let managed = isolatedPythonPath(iso, root: root)
        return ManagedPythonRuntime.isUsable(managed) ? managed : nil
    }

    /// An isolated interpreter esh can use, provisioning a dedicated venv from the esh-owned base interpreter if
    /// necessary (install/repair path). Never touches the main venv.
    private func ensureIsolatedPython(_ iso: IsolatedRuntime, root: PersistenceRoot,
                                      onProgress: @Sendable @escaping (Double) -> Void) async throws -> String {
        if let ready = adoptableIsolatedPython(iso, root: root) { onProgress(1.0); return ready }
        let runtime = ManagedPythonRuntime(root: root)
        let base = try await runtime.ensureBaseInterpreter(onProgress: { onProgress($0 * 0.8) })
        let venvURL = isolatedVenvURL(iso, root: root)
        try FileManager.default.createDirectory(at: venvURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ManagedPythonRuntime.createVenv(base: base, venv: venvURL)
        ManagedPythonRuntime.stripQuarantine(at: venvURL)
        onProgress(1.0)
        let py = isolatedPythonPath(iso, root: root)
        guard ManagedPythonRuntime.isUsable(py) else {
            throw CompatibilityError.runtimeUnavailable(reason: "esh could not provision the \(iso.dirName) runtime")
        }
        return py
    }

    /// The bridge-scripts directory: an injected dir (CLI), else the scripts shipped inside the SDK bundle.
    private func resolvedBridgeDir() -> String? {
        if let bridgeScriptsDir { return bridgeScriptsDir }
        return Self.bundledBridgeDir()
    }

    /// The esh-shipped bridge directory inside the package bundle (`Resources/bridge`). The consumer never
    /// supplies this — esh owns it.
    static func bundledBridgeDir() -> String? {
        guard let url = Bundle.module.url(forResource: "mlx_vlm_bridge", withExtension: "py", subdirectory: "bridge")
              ?? Bundle.module.url(forResource: "mlx_vlm_bridge", withExtension: "py") else { return nil }
        return url.deletingLastPathComponent().path
    }

    // MARK: - Preflight / repair (real, testable)

    public func inspect(_ manifest: CompatibilityEngineManifest) async -> CompatibilityEngineState {
        // Honest state before provisioning: nothing usable yet → the engine "requires download" (esh will
        // provision the interpreter + deps on install). Adopted managed venv or injected python → probe deps.
        let root = resolvedRoot()
        // Shared bridge deps are always probed against the main managed venv (the bridge runs there).
        guard let python = adoptablePython(root: root) else {
            return .requiresDownload(bytes: manifest.approxDownloadBytes)
        }
        for requirement in manifest.requiredModules {
            let (code, stderr) = Self.runProbe(python: python, module: requirement.module)
            if code != 0 { return Self.map(stderr: stderr, fallbackReason: "missing module '\(requirement.module)'") }
        }
        // Engines with an isolated runtime (voice-clone, AudioGen) have their heavy deps in a dedicated venv;
        // probe THOSE there, never against the main venv (which never has them → false "missing module").
        if let iso = manifest.isolatedRuntime {
            guard let isoPython = adoptableIsolatedPython(iso, root: root) else {
                return .requiresDownload(bytes: manifest.approxDownloadBytes)
            }
            for requirement in iso.modules {
                let (code, stderr) = Self.runProbe(python: isoPython, module: requirement.module)
                if code != 0 { return Self.map(stderr: stderr, fallbackReason: "missing module '\(requirement.module)'") }
            }
        }
        return .ready
    }

    public func install(_ manifest: CompatibilityEngineManifest, onProgress: @Sendable @escaping (Double) -> Void) async throws {
        let root = resolvedRoot()
        // Split progress: main-venv provisioning + deps, then (if any) the isolated venv + its deps.
        let hasIsolated = manifest.isolatedRuntime != nil
        let mainShare = hasIsolated ? 0.5 : 1.0
        let python = try await ensurePython(root: root, onProgress: { onProgress($0 * 0.5 * mainShare) })
        try Self.pipInstall(python: python, packages: manifest.requiredModules.map { $0.pipPackage },
                            onProgress: { onProgress((0.5 + $0 * 0.5) * mainShare) })
        if let iso = manifest.isolatedRuntime {
            let isoPython = try await ensureIsolatedPython(iso, root: root, onProgress: { onProgress(0.5 + $0 * 0.25) })
            try Self.pipInstall(python: isoPython, packages: iso.modules.map { $0.pipPackage },
                                onProgress: { onProgress(0.75 + $0 * 0.25) })
        }
    }

    public func repair(_ manifest: CompatibilityEngineManifest) async throws {
        let root = resolvedRoot()
        let python = try await ensurePython(root: root, onProgress: { _ in })
        let missing = manifest.requiredModules.filter { Self.runProbe(python: python, module: $0.module).code != 0 }
        if !missing.isEmpty {
            try Self.pipInstall(python: python, packages: missing.map { $0.pipPackage }, onProgress: { _ in })
        }
        if let iso = manifest.isolatedRuntime {
            let isoPython = try await ensureIsolatedPython(iso, root: root, onProgress: { _ in })
            let isoMissing = iso.modules.filter { Self.runProbe(python: isoPython, module: $0.module).code != 0 }
            if !isoMissing.isEmpty {
                try Self.pipInstall(python: isoPython, packages: isoMissing.map { $0.pipPackage }, onProgress: { _ in })
            }
        }
    }

    // MARK: - Execution (real bridge subprocess supervision)

    public func run(_ manifest: CompatibilityEngineManifest, _ request: ResolvedExecutionRequest,
                    context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        AsyncThrowingStream { continuation in
            // Resolve the esh-managed interpreter (adopted/provisioned by inspect+install before run) and the
            // esh-shipped bridge dir. The consumer supplied neither. Provisioning itself happens in install();
            // by the time run() is reached the provider's state machine has driven the engine to `.ready`.
            guard let python = adoptablePython(root: context.root) else {
                continuation.finish(throwing: CompatibilityError.runtimeUnavailable(reason: "esh-managed Python interpreter is not provisioned")); return
            }
            guard let dir = resolvedBridgeDir() else {
                continuation.finish(throwing: CompatibilityError.runtimeUnavailable(reason: "esh bridge scripts are missing from the SDK bundle")); return
            }
            let procBox = ProcessBox()
            let work = Task.detached {
                do {
                    // Gate on the configured assets volume before any heavy write: if the external storage
                    // volume is disconnected/mismatched, fail cleanly instead of falling back to internal disk.
                    do { try StorageService().ensureAssetsAvailable(root: context.root) }
                    catch { continuation.yield(.failed(message: "model storage is unavailable: \(error.localizedDescription)")); continuation.finish(); return }

                    let (command, outExt, artifactKind) = Self.bridgeCommand(for: manifest.id)
                    try FileManager.default.createDirectory(at: context.root.tempURL, withIntermediateDirectories: true)
                    let outPath = context.root.tempURL.appendingPathComponent(UUID().uuidString + "." + outExt).path
                    let requestJSON = try Self.bridgeRequest(manifest.id, request, outputPath: outPath, root: context.root)

                    continuation.yield(.status("running \(manifest.id.rawValue) engine"))
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: python)
                    proc.arguments = [dir + "/mlx_vlm_bridge.py", command]
                    proc.environment = self.bridgeEnvironment(for: manifest, root: context.root)
                    let stdin = Pipe(); let stdout = Pipe(); let stderr = Pipe()
                    proc.standardInput = stdin; proc.standardOutput = stdout; proc.standardError = stderr
                    procBox.set(proc)
                    try proc.run()
                    stdin.fileHandleForWriting.write(requestJSON)
                    try? stdin.fileHandleForWriting.close()

                    // Drain pipes off-thread so a large model can't deadlock on a full pipe buffer.
                    let errData = try await Self.readAll(stderr.fileHandleForReading)
                    _ = try await Self.readAll(stdout.fileHandleForReading)
                    proc.waitUntilExit()

                    if Task.isCancelled { continuation.finish(throwing: CancellationError()); return }
                    guard proc.terminationStatus == 0 else {
                        let stderrText = String(data: errData, encoding: .utf8) ?? ""
                        // A missing/broken dependency is a repair situation; anything else is an execution
                        // failure. Either way the consumer gets a clean typed error, never the traceback.
                        if let pkg = Self.moduleIssue(in: stderrText) {
                            throw CompatibilityError.engineRepairRequired(manifest.id, reason: "missing or broken Python module '\(pkg)'")
                        }
                        throw CompatibilityError.executionFailed(reason: Self.cleanReason(from: stderrText, status: proc.terminationStatus))
                    }
                    guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: outPath)), !bytes.isEmpty else {
                        throw CompatibilityError.executionFailed(reason: "engine produced no output")
                    }
                    let artifact = Artifact(
                        kind: artifactKind, mimeType: Self.mime(for: outExt), files: [], entrypoint: "output." + outExt,
                        generatedBy: ArtifactProvenance(providerID: "compat-\(manifest.id.rawValue)",
                                                        modelID: manifest.id.rawValue,
                                                        capability: manifest.capabilities.first))
                    let saved = try context.artifactStore.save(artifact, files: ["output." + outExt: bytes])
                    continuation.yield(.artifactProduced(saved))
                    continuation.yield(.done(finishReason: "stop"))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let e as CompatibilityError {
                    continuation.finish(throwing: e)
                } catch {
                    continuation.finish(throwing: CompatibilityError.executionFailed(reason: error.localizedDescription))
                }
            }
            continuation.onTermination = { reason in
                if case .cancelled = reason { procBox.terminate() }   // kill the subprocess — no orphan
                work.cancel()
            }
        }
    }

    // MARK: - Bridge protocol mapping

    static func bridgeCommand(for id: CompatibilityEngineID) -> (command: String, outputExt: String, artifact: ArtifactKind) {
        switch id {
        case .music:             return ("music-generate", "wav", .audio)
        case .soundFX:           return ("audio-generate", "wav", .audio)
        case .imageGeneration:   return ("image-generate", "png", .image)
        case .advancedImageEdit: return ("image-edit", "png", .image)
        case .diarization:       return ("audio-diarize", "json", .json)
        case .voiceClone:        return ("voice-clone", "wav", .audio)
        case .qwenImage21:       return ("image-generate-qwen21", "png", .image)
        }
    }

    static func bridgeRequest(_ id: CompatibilityEngineID, _ request: ResolvedExecutionRequest,
                              outputPath: String, root: PersistenceRoot) throws -> Data {
        let inputs = request.request.inputs
        func firstText() -> String { inputs.compactMap { if case .text(let t) = $0.payload { return t }; return nil }.joined(separator: " ") }
        func firstFile(_ kind: EshAttachment.Kind) -> String? {
            let uri = inputs.compactMap { if case .attachment(let a) = $0.payload, a.kind == kind { return a.uri }; return nil }.first ?? nil
            guard let uri else { return nil }
            // The bridge needs a filesystem path, not a URI. Resolve file:// URIs (which may be
            // percent-encoded, e.g. spaces in an external-volume path) to a real path.
            if uri.hasPrefix("file://"), let url = URL(string: uri), url.isFileURL { return url.path }
            return uri
        }
        func intOpt(_ k: String) -> Int? { if case .int(let v)? = request.request.options.values[k] { return v }; return nil }
        func dblOpt(_ k: String) -> Double? { switch request.request.options.values[k] { case .double(let d): return d; case .int(let i): return Double(i); default: return nil } }
        func strOpt(_ k: String) -> String? { if case .string(let v)? = request.request.options.values[k] { return v }; return nil }

        var dict: [String: Any] = ["outputPath": outputPath]
        switch id {
        case .music, .soundFX:
            dict["prompt"] = firstText()
            dict["seconds"] = dblOpt("seconds") ?? 8.0
            dict["seed"] = intOpt("seed") ?? 0
            // Route Hugging Face weights to the configured audio cache on the assets volume (external SSD),
            // reusing previously downloaded MusicGen/AudioGen assets instead of the internal `~/.cache`.
            dict["hfCache"] = root.pythonHFCacheURL(family: "audio").path
        case .imageGeneration:
            let prompt = firstText()
            guard !prompt.isEmpty else { throw CompatibilityError.executionFailed(reason: "image generation requires a text prompt") }
            dict["prompt"] = prompt
            if let w = intOpt("width") { dict["width"] = w }
            if let h = intOpt("height") { dict["height"] = h }
            if let s = intOpt("steps") { dict["steps"] = s }
            if let seed = intOpt("seed") { dict["seed"] = seed }
            // Reuse the Z-Image-Turbo mflux 4-bit model already on the assets volume (external SSD).
            dict["hfCache"] = root.pythonHFCacheURL(family: "image").path
        case .advancedImageEdit:
            guard let img = firstFile(.image) else { throw CompatibilityError.executionFailed(reason: "image edit requires an image input") }
            dict["imagePath"] = img
            dict["instruction"] = firstText()
            // Route FLUX/mflux weights to the configured image cache on the assets volume (external SSD).
            dict["hfCache"] = root.pythonHFCacheURL(family: "image").path
        case .diarization:
            guard let audio = firstFile(.audio) else { throw CompatibilityError.executionFailed(reason: "diarization requires an audio input") }
            dict["audioPath"] = audio
            if let n = intOpt("numSpeakers") { dict["numSpeakers"] = n }
            // The sherpa-onnx models live on the configured audio-assets volume (external SSD). The provider
            // passes their paths explicitly; the bridge never downloads them itself.
            dict["segModel"] = root.diarizationModelsURL.appendingPathComponent("segmentation.onnx").path
            dict["embModel"] = root.diarizationModelsURL.appendingPathComponent("embedding.onnx").path
            dict["hfCache"] = root.pythonHFCacheURL(family: "audio").path
        case .qwenImage21:
            // Text->image (image.generate) and img2img style conditioning (image.restyle). The bridge shells to
            // mflux-generate-qwen-2.1; an image input switches it to img2img (restyle). Only options the MFLUX
            // port actually consumes are forwarded (no ignored knobs).
            let prompt = firstText()
            guard !prompt.isEmpty else { throw CompatibilityError.executionFailed(reason: "Qwen-Image-2.1 requires a text prompt") }
            dict["prompt"] = prompt
            dict["steps"] = intOpt("steps") ?? 40                    // qwen-2.1 recommended default
            dict["seed"] = intOpt("seed") ?? 0
            if let w = intOpt("width") { dict["width"] = w }
            if let h = intOpt("height") { dict["height"] = h }
            if let g = dblOpt("guidance") { dict["guidance"] = g }   // >1 enables true CFG (needs negativePrompt)
            if let np = strOpt("negativePrompt") { dict["negativePrompt"] = np }
            // Quantization of the transformer/VAE (the Qwen3-VL text encoder stays bf16). Default q8 keeps the
            // peak as low as the port allows on a 32 GB Mac; override via options.
            dict["quantize"] = intOpt("quantize") ?? 8
            if let img = firstFile(.image) {                        // present → img2img restyle
                dict["imagePath"] = img
                if let s = dblOpt("imageStrength") { dict["imageStrength"] = s }
            }
            if let m = strOpt("model") { dict["model"] = m }
            dict["hfCache"] = root.pythonHFCacheURL(family: "image").path
        case .voiceClone:
            let text = firstText()
            guard !text.isEmpty else { throw CompatibilityError.executionFailed(reason: "voice cloning requires text to speak") }
            guard let reference = firstFile(.audio) else { throw CompatibilityError.executionFailed(reason: "voice cloning requires a reference audio sample") }
            dict["text"] = text
            dict["referencePath"] = reference
            dict["language"] = strOpt("language") ?? "en"
            // XTTS weights + coqui-tts model store live on the configured audio-assets volume (external SSD).
            dict["hfCache"] = root.pythonHFCacheURL(family: "audio").path
        }
        return try JSONSerialization.data(withJSONObject: dict)
    }

    /// The subprocess environment that keeps ALL heavy Hugging Face / temp I/O on the configured assets
    /// volume (external SSD), never the internal disk. Belt-and-suspenders alongside the per-request
    /// `hfCache` field: some libraries freeze their cache dir from the environment at import time.
    func bridgeEnvironment(for manifest: CompatibilityEngineManifest, root: PersistenceRoot) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let family: String
        switch manifest.id {
        case .imageGeneration, .advancedImageEdit, .qwenImage21: family = "image"
        default: family = "audio"
        }
        let hf = root.pythonHFCacheURL(family: family).path
        try? FileManager.default.createDirectory(atPath: hf + "/hub", withIntermediateDirectories: true)
        env["HF_HOME"] = hf
        env["HF_HUB_CACHE"] = hf + "/hub"
        env["HUGGINGFACE_HUB_CACHE"] = hf + "/hub"
        // Route temporary/staging writes (e.g. large intermediate tensors) to the assets volume too.
        try? FileManager.default.createDirectory(at: root.tempURL, withIntermediateDirectories: true)
        env["TMPDIR"] = root.tempURL.path
        // Point the bridge at this engine's isolated runtime (voice-clone, AudioGen) when one exists — the
        // env override the bridge reads. Prefer an already-usable interpreter (an ambient override or an
        // externally-provisioned venv) and fall back to the esh-managed isolated venv path.
        if let iso = manifest.isolatedRuntime, let py = adoptableIsolatedPython(iso, root: root) {
            env[iso.envVar] = py
        }
        return env
    }

    static func mime(for ext: String) -> String {
        switch ext { case "wav": return "audio/wav"; case "png": return "image/png"; case "json": return "application/json"; default: return "application/octet-stream" }
    }

    /// A clean one-line reason from stderr — never the whole multiline traceback.
    static func cleanReason(from stderr: String, status: Int32) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline).map(String.init)
        if let errLine = lines.last(where: { $0.contains("Error") || $0.lowercased().contains("failed") }) {
            return String(errLine.prefix(200))
        }
        return "engine exited with status \(status)"
    }

    // MARK: - Real, testable helpers

    static func map(stderr: String, fallbackReason: String) -> CompatibilityEngineState {
        if let pkg = moduleIssue(in: stderr) { return .repairRequired(reason: "missing Python module '\(pkg)'") }
        return .repairRequired(reason: fallbackReason)
    }

    /// The offending package name when stderr indicates a missing OR broken (dlopen-failed) dependency,
    /// else nil. Catches `No module named 'X'` and a failed dlopen of a `site-packages/<pkg>/…` binary.
    static func moduleIssue(in stderr: String) -> String? {
        if let range = stderr.range(of: #"No module named '([^']+)'"#, options: .regularExpression) {
            return String(stderr[range]).replacingOccurrences(of: "No module named '", with: "").dropLast().description
                .split(separator: ".").first.map(String.init)
        }
        if stderr.contains("dlopen("), let r = stderr.range(of: #"site-packages/([A-Za-z0-9_]+)/"#, options: .regularExpression) {
            return String(stderr[r]).replacingOccurrences(of: "site-packages/", with: "").replacingOccurrences(of: "/", with: "")
        }
        return nil
    }

    static func runProbe(python: String, module: String) -> (code: Int32, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-c", "import \(module)"]
        let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
        do { try p.run() } catch { return (127, "\(error)") }
        p.waitUntilExit()
        let data = err.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    static func pipInstall(python: String, packages: [String], onProgress: @Sendable (Double) -> Void) throws {
        guard !packages.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-m", "pip", "install", "--disable-pip-version-check"] + packages
        let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
        try p.run(); onProgress(0.5); p.waitUntilExit(); onProgress(1.0)
        if p.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "pip failed"
            throw CompatibilityError.dependencyInstallationFailed(reason: String(msg.suffix(300)))
        }
        // On volumes without native extended attributes (exFAT/FAT — common for external asset volumes),
        // macOS writes AppleDouble `._*` sidecars during the install. Python package directory scans (e.g.
        // transformers importing its `models/`) read `._*.py` as UTF-8 source and crash. Strip them so module
        // discovery works. No-op on APFS/HFS+ where the sidecars aren't created. (The managed venv now lives
        // on the internal APFS state root, so this is normally a no-op; kept as defense in depth.)
        Self.stripAppleDoubleFiles(inVenvFor: python)
        // Quarantine hygiene after dependency install: any freshly written binary that inherited
        // `com.apple.quarantine` (sandboxed context) would fail to exec. Strip it from the venv tree.
        let venvRoot = URL(fileURLWithPath: python).deletingLastPathComponent().deletingLastPathComponent()
        ManagedPythonRuntime.stripQuarantine(at: venvRoot)
    }

    /// Remove macOS AppleDouble `._*` sidecars from an esh-managed venv (see `pipInstall`). Returns the count
    /// removed. Idempotent and safe on filesystems that never create them.
    @discardableResult
    static func stripAppleDoubleFiles(inVenvFor python: String) -> Int {
        // python is `<venv>/bin/python*`; scan the venv's library tree where packages live.
        let venvRoot = URL(fileURLWithPath: python).deletingLastPathComponent().deletingLastPathComponent()
        return stripAppleDoubleFiles(in: venvRoot.appendingPathComponent("lib", isDirectory: true))
    }

    @discardableResult
    static func stripAppleDoubleFiles(in directory: URL) -> Int {
        // NOTE: macOS's Foundation directory enumerators hide AppleDouble `._*` sidecars, so a Swift-level
        // scan can't see (or delete) them — `find` can. Delete-and-print, then count the printed paths.
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/find")
        p.arguments = [directory.path, "-name", "._*", "-type", "f", "-print", "-delete"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return 0 }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(whereSeparator: \.isNewline).count
    }

    static func readAll(_ handle: FileHandle) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async { cont.resume(returning: handle.readDataToEndOfFile()) }
        }
    }

    final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock(); private var proc: Process?
        func set(_ p: Process) { lock.lock(); proc = p; lock.unlock() }
        func terminate() { lock.lock(); let p = proc; lock.unlock(); p?.terminate() }
    }
}

#endif
