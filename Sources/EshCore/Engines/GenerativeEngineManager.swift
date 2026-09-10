import Foundation

/// Runtime status of one generative engine — whether its Python runtime is actually present (not just whether
/// model weights were downloaded). Serializable for `/v1/engines` and the web UI's engine manager.
public struct GenerativeEngineStatus: Codable, Sendable, Equatable {
    public var id: String                 // GenerativeEngineID raw value
    public var displayName: String
    public var summary: String
    public var installed: Bool            // the engine's Python runtime is importable/usable
    public var venvPath: String?          // where it's installed (for isolated engines)
    public var approxSizeMB: Int
    public var commercialSafe: Bool
    public var licenseNote: String?
    public var capabilities: [String]     // capability raw values this engine powers
    public var installKind: String        // "main" | "isolated"

    public init(id: String, displayName: String, summary: String, installed: Bool, venvPath: String?,
                approxSizeMB: Int, commercialSafe: Bool, licenseNote: String?, capabilities: [String], installKind: String) {
        self.id = id; self.displayName = displayName; self.summary = summary; self.installed = installed
        self.venvPath = venvPath; self.approxSizeMB = approxSizeMB; self.commercialSafe = commercialSafe
        self.licenseNote = licenseNote; self.capabilities = capabilities; self.installKind = installKind
    }
}

/// Coarse install progress. pip gives no reliable byte-level progress, so we report phases (the UI shows a
/// spinner + phase); model weights download separately on first execution via the normal capability path.
public struct EngineInstallProgress: Sendable, Equatable {
    public enum Phase: String, Sendable { case resolving, creatingEnv = "creating-env", installing, verifying, installed, failed }
    public var phase: Phase
    public var detail: String?
    public init(_ phase: Phase, detail: String? = nil) { self.phase = phase; self.detail = detail }
}

/// Installs / probes / removes generative engines. esh owns this so clients never touch pip or a venv.
/// Probes are pure on-disk (fast, no subprocess) so `/v1/engines` and doctor stay cheap. Installs shell out to
/// the resolved Python (`$ESH_PYTHON` for `.main`; a freshly-built venv for `.isolated`).
public struct GenerativeEngineManager: Sendable {
    private let root: PersistenceRoot
    public init(root: PersistenceRoot) { self.root = root }

    // MARK: - Python resolution

    /// esh's main managed interpreter ($ESH_PYTHON / bundled / venv), the base for `.main` installs and the
    /// base interpreter used to build isolated venvs.
    public func mainPython() -> URL {
        RuntimePathResolver.pythonExecutableURL(
            configuredPath: nil,
            environment: ProcessInfo.processInfo.environment,
            executablePath: ExecutablePath.resolvedPath,
            sourceFilePath: #filePath
        )
    }

    /// venv root for a python at `<root>/bin/python[3]`.
    private func venvRoot(ofPython python: URL) -> URL {
        python.deletingLastPathComponent().deletingLastPathComponent()
    }

    /// site-packages dir(s) under a venv root: `<root>/lib/python*/site-packages`.
    private func sitePackages(inVenvRoot venvRoot: URL) -> [URL] {
        let lib = venvRoot.appendingPathComponent("lib")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: lib.path) else { return [] }
        return entries.filter { $0.hasPrefix("python") }
            .map { lib.appendingPathComponent($0).appendingPathComponent("site-packages") }
    }

    /// A module is present if its package dir or a matching *.dist-info exists in any site-packages dir.
    private func moduleInstalled(_ module: String, sitePackages dirs: [URL]) -> Bool {
        let fm = FileManager.default
        let distPrefix = module.replacingOccurrences(of: "-", with: "_").lowercased()
        for dir in dirs {
            if fm.fileExists(atPath: dir.appendingPathComponent(module).path) { return true }
            if fm.fileExists(atPath: dir.appendingPathComponent("\(module).py").path) { return true }
            if let entries = try? fm.contentsOfDirectory(atPath: dir.path) {
                if entries.contains(where: { $0.lowercased().hasPrefix(distPrefix) && $0.hasSuffix(".dist-info") }) { return true }
            }
        }
        return false
    }

    /// The venv root to CREATE for an isolated engine: under the CONFIGURED ASSETS ROOT, so it follows the
    /// user's storage choice (internal by default, external SSD when set) exactly like models.
    private func installVenvRoot(_ target: EngineVenvTarget) -> URL? {
        guard case let .isolated(_, subdir, _) = target else { return nil }
        return root.assetsRootURL.appendingPathComponent(subdir, isDirectory: true)
    }

    /// For an isolated engine, the venv root that currently EXISTS: the exported env var, then the assets-root
    /// location, then the pre-2.3 legacy paths (so existing installs keep working after the move).
    private func existingIsolatedVenvRoot(_ target: EngineVenvTarget) -> URL? {
        guard case let .isolated(envVar, _, legacy) = target else { return nil }
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment[envVar], !env.isEmpty {
            candidates.append(venvRoot(ofPython: URL(fileURLWithPath: env)).path)   // env points at the python
        }
        if let install = installVenvRoot(target) { candidates.append(install.path) }
        candidates.append(contentsOf: legacy.map { ($0 as NSString).expandingTildeInPath })
        for p in candidates {
            let r = URL(fileURLWithPath: p)
            if FileManager.default.isExecutableFile(atPath: r.appendingPathComponent("bin/python").path)
                || FileManager.default.isExecutableFile(atPath: r.appendingPathComponent("bin/python3").path) {
                return r
            }
        }
        return nil
    }

    /// Export discovery env vars (e.g. ESH_AUDIOGEN_PYTHON) for every installed isolated engine so the Python
    /// bridge finds them wherever the user's storage put them. Call at server startup and after an install; the
    /// bridge subprocess inherits the parent environment (ProcessRunner doesn't wipe it).
    public func exportInstalledEngineEnvironment() {
        for spec in GenerativeEngineCatalog.all {
            guard case let .isolated(envVar, _, _) = spec.venv, let venv = existingIsolatedVenvRoot(spec.venv) else { continue }
            let py = venv.appendingPathComponent("bin/python3")
            let python = FileManager.default.isExecutableFile(atPath: py.path) ? py : venv.appendingPathComponent("bin/python")
            setenv(envVar, python.path, 1)
        }
    }

    // MARK: - Probe

    public func isInstalled(_ spec: GenerativeEngineSpec) -> Bool {
        switch spec.venv {
        case .main:
            let venv = venvRoot(ofPython: mainPython())
            if let cli = spec.probeCLI,
               FileManager.default.isExecutableFile(atPath: venv.appendingPathComponent("bin/\(cli)").path) { return true }
            return moduleInstalled(spec.probeModule, sitePackages: sitePackages(inVenvRoot: venv))
        case .isolated:
            guard let venv = existingIsolatedVenvRoot(spec.venv) else { return false }
            if let cli = spec.probeCLI,
               FileManager.default.isExecutableFile(atPath: venv.appendingPathComponent("bin/\(cli)").path) { return true }
            return moduleInstalled(spec.probeModule, sitePackages: sitePackages(inVenvRoot: venv))
        }
    }

    public func status(_ spec: GenerativeEngineSpec) -> GenerativeEngineStatus {
        let installed = isInstalled(spec)
        var venvPath: String?
        if case .isolated = spec.venv { venvPath = existingIsolatedVenvRoot(spec.venv)?.path }
        else if installed { venvPath = venvRoot(ofPython: mainPython()).path }
        let kind: String = { if case .main = spec.venv { return "main" }; return "isolated" }()
        return GenerativeEngineStatus(
            id: spec.id.rawValue, displayName: spec.displayName, summary: spec.summary,
            installed: installed, venvPath: venvPath, approxSizeMB: spec.approxSizeMB,
            commercialSafe: spec.commercialSafe, licenseNote: spec.licenseNote,
            capabilities: spec.capabilities.map { $0.rawValue }, installKind: kind)
    }

    public func statusAll() -> [GenerativeEngineStatus] {
        GenerativeEngineCatalog.all.map { status($0) }
    }

    // MARK: - Install

    /// Install the engine's Python runtime. Blocking (runs pip); call from a background Task. Cooperative
    /// cancellation via `runCancellable`. `progress` is invoked as phases advance.
    public func install(_ spec: GenerativeEngineSpec, progress: @Sendable (EngineInstallProgress) -> Void = { _ in }) throws {
        progress(.init(.resolving))
        let pythonForPip: URL
        switch spec.venv {
        case .main:
            pythonForPip = mainPython()
        case let .isolated(envVar, _, _):
            // Installs to the configured assets root (internal or external per the user's storage choice), so
            // require that volume to be present before writing a multi-hundred-MB venv.
            try StorageService().ensureAssetsAvailable(root: root)
            guard let venvRootURL = existingIsolatedVenvRoot(spec.venv) ?? installVenvRoot(spec.venv) else {
                throw StoreError.invalidManifest("No install location for engine \(spec.id.rawValue).")
            }
            let venvPython = venvRootURL.appendingPathComponent("bin/python3")
            if !FileManager.default.isExecutableFile(atPath: venvPython.path) {
                progress(.init(.creatingEnv, detail: venvRootURL.path))
                try FileManager.default.createDirectory(at: venvRootURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try runStep(mainPython(), ["-m", "venv", "--copies", venvRootURL.path], label: "create venv")
            }
            pythonForPip = venvPython
            // Export the discovery env var now so this process's bridge spawns find the freshly-built venv.
            setenv(envVar, venvPython.path, 1)
        }

        progress(.init(.installing, detail: spec.pipPackages.joined(separator: " ")))
        // Keep pip quiet-ish but resilient; upgrade pip first so wheels resolve on newer Pythons.
        try runStep(pythonForPip, ["-m", "pip", "install", "--upgrade", "pip"], label: "upgrade pip")
        try runStep(pythonForPip, ["-m", "pip", "install", "--upgrade"] + spec.pipPackages, label: "install \(spec.displayName)")

        // exFAT (external SSD) drops AppleDouble `._*` sidecars that break imports — strip them like the
        // AudioGen setup script does.
        if case .isolated = spec.venv { stripAppleDoubles(underVenvOfPython: pythonForPip) }

        progress(.init(.verifying))
        guard isInstalled(spec) else {
            throw StoreError.invalidManifest("\(spec.displayName) installed but its runtime (\(spec.probeModule)) still isn't importable.")
        }
        progress(.init(.installed))
    }

    private func runStep(_ python: URL, _ args: [String], label: String) throws {
        let out = try ProcessRunner.runCancellable(executableURL: python, arguments: args)
        guard out.exitCode == 0 else {
            let err = String(decoding: out.stderr, as: UTF8.self)
            let so = String(decoding: out.stdout, as: UTF8.self)
            let msg = (err.isEmpty ? so : err).trimmingCharacters(in: .whitespacesAndNewlines)
            throw StoreError.invalidManifest("\(label) failed: \(String(msg.suffix(600)))")
        }
    }

    private func stripAppleDoubles(underVenvOfPython python: URL) {
        let venv = venvRoot(ofPython: python)
        _ = try? ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/find"),
                                   arguments: [venv.path, "-name", "._*", "-delete"])
    }

    // MARK: - Remove

    /// Remove an engine. Isolated engines delete their venv cleanly. `.main` engines pip-uninstall only their
    /// OWN top-level packages (shared deps like onnxruntime are left; removing them could break another engine).
    public func remove(_ spec: GenerativeEngineSpec) throws {
        switch spec.venv {
        case .isolated:
            guard let venv = existingIsolatedVenvRoot(spec.venv) else { return }
            try FileManager.default.removeItem(at: venv)
        case .main:
            // Uninstall only packages unique to this engine (never a dep another installed engine also needs).
            let shared = sharedMainPackages(excluding: spec)
            let toRemove = spec.pipPackages
                .map { pipName($0) }
                .filter { !shared.contains($0.lowercased()) }
            guard !toRemove.isEmpty else { return }
            try runStep(mainPython(), ["-m", "pip", "uninstall", "-y"] + toRemove, label: "remove \(spec.displayName)")
        }
    }

    /// Lowercased pip package names required by OTHER installed `.main` engines (so remove never breaks them).
    private func sharedMainPackages(excluding: GenerativeEngineSpec) -> Set<String> {
        var shared = Set<String>()
        for other in GenerativeEngineCatalog.all where other.id != excluding.id {
            if case .main = other.venv, isInstalled(other) {
                for pkg in other.pipPackages { shared.insert(pipName(pkg).lowercased()) }
            }
        }
        return shared
    }

    /// Strip a version specifier from a pip requirement (`mlx-audiocraft==0.1.0` → `mlx-audiocraft`).
    private func pipName(_ requirement: String) -> String {
        for sep in ["==", ">=", "<=", "~=", ">", "<", "!="] {
            if let r = requirement.range(of: sep) { return String(requirement[..<r.lowerBound]) }
        }
        return requirement
    }
}
