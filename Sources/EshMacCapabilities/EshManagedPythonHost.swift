import Foundation
import EshCore
import EshRuntime

#if os(macOS)

// The concrete esh-owned macOS host: manages a Python runtime esh controls (never the consumer's), probes
// declared modules for preflight, repairs missing dependencies via pip, and supervises the model-execution
// bridge subprocess. A consumer never sees Python — only states/events/artifacts through the provider.
//
// Honesty on scope: module probing, dependency repair over an esh-managed venv, and the bridge subprocess
// supervision (spawn/stdin-JSON/output-artifact/cancel/error-map) are implemented and validatable against a
// real interpreter + the shipped bridge scripts. Provisioning a relocatable interpreter on a truly clean
// machine (python-build-standalone) is the remaining productionization; `pythonPath` is injected so esh
// owns it and this host stays real + testable.
public final class EshManagedPythonHost: CompatibilityEngineHost, @unchecked Sendable {
    private let pythonPath: String?
    private let bridgeScriptsDir: String?     // dir containing mlx_vlm_bridge.py (shipped by esh, not the consumer)

    public init(pythonPath: String?, bridgeScriptsDir: String?) {
        self.pythonPath = pythonPath
        self.bridgeScriptsDir = bridgeScriptsDir
    }

    // MARK: - Preflight / repair (real, testable)

    public func inspect(_ manifest: CompatibilityEngineManifest) async -> CompatibilityEngineState {
        guard let python = pythonPath, FileManager.default.isExecutableFile(atPath: python) else {
            return .requiresDownload(bytes: manifest.approxDownloadBytes)
        }
        for requirement in manifest.requiredModules {
            let (code, stderr) = Self.runProbe(python: python, module: requirement.module)
            if code != 0 { return Self.map(stderr: stderr, fallbackReason: "missing module '\(requirement.module)'") }
        }
        return .ready
    }

    public func install(_ manifest: CompatibilityEngineManifest, onProgress: @Sendable @escaping (Double) -> Void) async throws {
        guard let python = pythonPath, FileManager.default.isExecutableFile(atPath: python) else {
            throw CompatibilityError.runtimeUnavailable(reason: "esh-managed Python interpreter is not provisioned")
        }
        try Self.pipInstall(python: python, packages: manifest.requiredModules.map { $0.pipPackage }, onProgress: onProgress)
    }

    public func repair(_ manifest: CompatibilityEngineManifest) async throws {
        guard let python = pythonPath, FileManager.default.isExecutableFile(atPath: python) else {
            throw CompatibilityError.runtimeUnavailable(reason: "esh-managed Python interpreter is not provisioned")
        }
        let missing = manifest.requiredModules.filter { Self.runProbe(python: python, module: $0.module).code != 0 }
        guard !missing.isEmpty else { return }
        try Self.pipInstall(python: python, packages: missing.map { $0.pipPackage }, onProgress: { _ in })
    }

    // MARK: - Execution (real bridge subprocess supervision)

    public func run(_ manifest: CompatibilityEngineManifest, _ request: ResolvedExecutionRequest,
                    context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let python = pythonPath, let dir = bridgeScriptsDir else {
                continuation.finish(throwing: CompatibilityError.runtimeUnavailable(reason: "bridge is not configured")); return
            }
            let procBox = ProcessBox()
            let work = Task.detached {
                do {
                    let (command, outExt, artifactKind) = Self.bridgeCommand(for: manifest.id)
                    try FileManager.default.createDirectory(at: context.root.tempURL, withIntermediateDirectories: true)
                    let outPath = context.root.tempURL.appendingPathComponent(UUID().uuidString + "." + outExt).path
                    let requestJSON = try Self.bridgeRequest(manifest.id, request, outputPath: outPath)

                    continuation.yield(.status("running \(manifest.id.rawValue) engine"))
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: python)
                    proc.arguments = [dir + "/mlx_vlm_bridge.py", command]
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
                        generatedBy: ArtifactProvenance(providerID: "compat-\(manifest.id.rawValue)", capability: manifest.capabilities.first))
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
        case .advancedImageEdit: return ("image-edit", "png", .image)
        case .diarization:       return ("audio-diarize", "json", .json)
        }
    }

    static func bridgeRequest(_ id: CompatibilityEngineID, _ request: ResolvedExecutionRequest, outputPath: String) throws -> Data {
        let inputs = request.request.inputs
        func firstText() -> String { inputs.compactMap { if case .text(let t) = $0.payload { return t }; return nil }.joined(separator: " ") }
        func firstFile(_ kind: EshAttachment.Kind) -> String? {
            inputs.compactMap { if case .attachment(let a) = $0.payload, a.kind == kind { return a.uri }; return nil }.first ?? nil
        }
        func intOpt(_ k: String) -> Int? { if case .int(let v)? = request.request.options.values[k] { return v }; return nil }
        func dblOpt(_ k: String) -> Double? { switch request.request.options.values[k] { case .double(let d): return d; case .int(let i): return Double(i); default: return nil } }

        var dict: [String: Any] = ["outputPath": outputPath]
        switch id {
        case .music, .soundFX:
            dict["prompt"] = firstText()
            dict["seconds"] = dblOpt("seconds") ?? 8.0
            dict["seed"] = intOpt("seed") ?? 0
        case .advancedImageEdit:
            guard let img = firstFile(.image) else { throw CompatibilityError.executionFailed(reason: "image edit requires an image input") }
            dict["inputPath"] = img
            dict["instruction"] = firstText()
        case .diarization:
            guard let audio = firstFile(.audio) else { throw CompatibilityError.executionFailed(reason: "diarization requires an audio input") }
            dict["audioPath"] = audio
            if let n = intOpt("numSpeakers") { dict["numSpeakers"] = n }
        }
        return try JSONSerialization.data(withJSONObject: dict)
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
