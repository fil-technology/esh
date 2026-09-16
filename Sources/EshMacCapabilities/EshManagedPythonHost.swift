import Foundation
import EshCore
import EshRuntime

#if os(macOS)

// The concrete esh-owned macOS host: manages a Python runtime esh controls (never the consumer's), probes
// declared modules for preflight, repairs missing dependencies, and supervises the model-execution bridge.
// A consumer never sees Python — it only gets states/events/artifacts through the provider.
//
// Scope note (honesty): module probing + dependency repair over an esh-managed venv are implemented and
// validatable against a real interpreter. The full clean-machine bootstrap (provisioning a relocatable
// interpreter + multi-GB model downloads) and the concrete model-execution bridge are configured where esh's
// bridge assets are shipped and validated on real hardware; `run` and interpreter-provisioning are injected
// so this host stays real and testable without hardcoding an unvalidated multi-GB path.
public final class EshManagedPythonHost: CompatibilityEngineHost, @unchecked Sendable {
    /// Absolute path to esh's managed Python interpreter (in an esh-owned support dir). When nil / missing,
    /// engines report `.requiresDownload` (the interpreter itself must be provisioned first).
    private let pythonPath: String?
    /// Injected model-execution bridge. esh owns process supervision around it; the specific invocation is
    /// provided where the bridge scripts are shipped. Default: honest `runtimeUnavailable`.
    private let runBridge: @Sendable (CompatibilityEngineManifest, ResolvedExecutionRequest, ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error>

    public init(pythonPath: String?,
                runBridge: @escaping @Sendable (CompatibilityEngineManifest, ResolvedExecutionRequest, ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> = EshManagedPythonHost.unavailableBridge) {
        self.pythonPath = pythonPath
        self.runBridge = runBridge
    }

    public static let unavailableBridge: @Sendable (CompatibilityEngineManifest, ResolvedExecutionRequest, ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> = { _, _, _ in
        AsyncThrowingStream { $0.finish(throwing: CompatibilityError.runtimeUnavailable(reason: "model-execution bridge is not configured in this build")) }
    }

    public func inspect(_ manifest: CompatibilityEngineManifest) async -> CompatibilityEngineState {
        guard let python = pythonPath, FileManager.default.isExecutableFile(atPath: python) else {
            return .requiresDownload(bytes: manifest.approxDownloadBytes)
        }
        // Probe each declared module; the first missing one is the honest, repairable failure.
        for requirement in manifest.requiredModules {
            let (code, stderr) = Self.runProbe(python: python, module: requirement.module)
            if code != 0 {
                return Self.map(stderr: stderr, fallbackReason: "missing module '\(requirement.module)'")
            }
        }
        return .ready
    }

    public func install(_ manifest: CompatibilityEngineManifest, onProgress: @Sendable @escaping (Double) -> Void) async throws {
        guard let python = pythonPath, FileManager.default.isExecutableFile(atPath: python) else {
            throw CompatibilityError.runtimeUnavailable(reason: "esh-managed Python interpreter is not provisioned")
        }
        try Self.pipInstall(python: python, packages: manifest.requiredModules.map { $0.pipPackage }, onProgress: onProgress)
        // Model assets are fetched through esh's model catalog (not shown here); validated on hardware.
    }

    public func repair(_ manifest: CompatibilityEngineManifest) async throws {
        guard let python = pythonPath, FileManager.default.isExecutableFile(atPath: python) else {
            throw CompatibilityError.runtimeUnavailable(reason: "esh-managed Python interpreter is not provisioned")
        }
        // Reinstall only the modules that fail to import — targeted repair, no full wipe.
        let missing = manifest.requiredModules.filter { Self.runProbe(python: python, module: $0.module).code != 0 }
        guard !missing.isEmpty else { return }
        try Self.pipInstall(python: python, packages: missing.map { $0.pipPackage }, onProgress: { _ in })
    }

    public func run(_ manifest: CompatibilityEngineManifest, _ request: ResolvedExecutionRequest,
                    context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        runBridge(manifest, request, context)
    }

    // MARK: - Real, testable helpers

    /// Turn a Python failure (stderr/traceback) into a typed, clean state — NEVER a raw traceback.
    /// `ModuleNotFoundError: No module named 'X'` → `.repairRequired` (this is the `soundfile` case).
    static func map(stderr: String, fallbackReason: String) -> CompatibilityEngineState {
        if let range = stderr.range(of: #"No module named '([^']+)'"#, options: .regularExpression) {
            let name = String(stderr[range]).replacingOccurrences(of: "No module named '", with: "").dropLast()
            return .repairRequired(reason: "missing Python module '\(name)'")
        }
        return .repairRequired(reason: fallbackReason)
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
}

#endif
