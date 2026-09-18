import Foundation
import EshCore
import EshRuntime
import CryptoKit
import Darwin   // removexattr / XATTR_NOFOLLOW — in-process quarantine removal (sandbox-safe)

#if os(macOS)

/// esh-owned provisioning of the managed Python runtime for the macOS compatibility engines.
///
/// A consumer never supplies a Python path, venv, bridge dir, or Homebrew install. This type:
///  - resolves the canonical managed venv under the configured assets root (external volume when set),
///  - **adopts** an already-provisioned compatible venv (reused across launches — idempotent),
///  - otherwise **provisions** a relocatable interpreter esh controls (python-build-standalone; no Homebrew),
///    creates the venv, and returns it,
///  - reports the honest state (`.requiresDownload` when nothing usable is present yet).
///
/// Dependency install/repair (pip) is layered on top by `EshManagedPythonHost`.
struct ManagedPythonRuntime {
    static let requiredMajor = 3
    static let requiredMinor = 11

    /// Pinned python-build-standalone build (Apple Silicon, install_only, relocatable). URL + sha256 verified
    /// 2026-09-17 (downloaded, checksummed, and used to create a venv with no Homebrew). Overridable via env
    /// for staging, mirroring the `ESH_LLAMA_XCFRAMEWORK_URL` precedent.
    static let defaultStandaloneURL =
        "https://github.com/astral-sh/python-build-standalone/releases/download/20240814/cpython-3.11.9+20240814-aarch64-apple-darwin-install_only.tar.gz"
    static let defaultStandaloneSHA256 = "8760e908f25fdc8a01f4d1b101854ac047b4eacb723fb2593a168fb989c86eef"

    let root: PersistenceRoot
    /// The relocatable base-interpreter build to fetch when provisioning from scratch. Defaults to the pinned
    /// python-build-standalone for this arch; injectable so tests can exercise download/verify failure paths
    /// without mutating process environment.
    let standalone: (url: URL, sha256: String?)?

    init(root: PersistenceRoot, standalone: (url: URL, sha256: String?)? = ManagedPythonRuntime.standaloneSpec()) {
        self.root = root
        self.standalone = standalone
    }

    // MARK: Canonical paths (pure — the persistence contract, reused across launches)

    /// The managed runtime (interpreter + venv + bridge/runtime state) lives under the INTERNAL state root
    /// (`PersistenceRoot.rootURL`), never the relocatable assets volume. Two reasons, both found via Esh
    /// Studio dogfood: (1) the assets volume is commonly exFAT, where macOS xattrs (`com.apple.provenance`)
    /// become AppleDouble `._*` sidecars — Python metadata scans then choke on `._METADATA`; APFS stores
    /// xattrs natively. (2) `PersistenceRoot.rootURL` is by contract the home of internal state including the
    /// runtime, and must not follow external model storage. Model weights / HF caches stay on `assetsRootURL`
    /// (see `pythonHFCacheURL`, `bridgeEnvironment`) — unchanged.
    var runtimeRootURL: URL { root.stateRootURL.appendingPathComponent("runtime/py311", isDirectory: true) }
    var venvURL: URL { runtimeRootURL.appendingPathComponent("venv", isDirectory: true) }
    var venvPythonPath: String { venvURL.appendingPathComponent("bin/python3").path }
    /// Where the esh-owned relocatable base interpreter is extracted (python-build-standalone).
    var baseStandaloneDirURL: URL { runtimeRootURL.appendingPathComponent("base", isDirectory: true) }
    var baseStandalonePythonPath: String { baseStandaloneDirURL.appendingPathComponent("python/bin/python3").path }

    // MARK: Usability / adoption (real, testable against any interpreter)

    /// `(major, minor)` reported by an interpreter, or nil if it can't run.
    static func pythonVersion(_ path: String) -> (Int, Int)? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-c", "import sys;print(f'{sys.version_info[0]}.{sys.version_info[1]}')"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              case let parts = text.split(separator: "."), parts.count == 2,
              let maj = Int(parts[0]), let min = Int(parts[1]) else { return nil }
        return (maj, min)
    }

    /// An interpreter esh can use: executable and at least Python 3.11.
    static func isUsable(_ path: String) -> Bool {
        guard let (maj, min) = pythonVersion(path) else { return false }
        return maj > requiredMajor || (maj == requiredMajor && min >= requiredMinor)
    }

    // MARK: Provisioning (adopt → provision), idempotent

    /// A ready managed venv interpreter. Adopts an existing compatible venv, else provisions one. Idempotent
    /// and safe to call every launch — the fast path is a single version probe.
    func provisionedPython(onProgress: @Sendable (Double) -> Void) async throws -> String {
        if Self.isUsable(venvPythonPath) { onProgress(1.0); return venvPythonPath }   // adopt existing venv
        onProgress(0.01)   // immediate heartbeat so the consumer UI reflects "provisioning" before any I/O
        try FileManager.default.createDirectory(at: runtimeRootURL, withIntermediateDirectories: true)
        let base = try await ensureBaseInterpreter(onProgress: { onProgress($0 * 0.7) })
        onProgress(0.72)
        try Self.createVenv(base: base, venv: venvURL)
        Self.stripQuarantine(at: venvURL)   // the venv's python symlinks/binaries inherit no quarantine here,
                                            // but strip defensively so a sandboxed exec is never blocked.
        onProgress(0.95)
        guard Self.isUsable(venvPythonPath) else {
            throw CompatibilityError.runtimeUnavailable(reason: "esh-managed venv did not become usable after provisioning")
        }
        onProgress(1.0)
        return venvPythonPath
    }

    /// An esh-owned base interpreter (>= 3.11). Reuses an already-extracted standalone build, else downloads,
    /// verifies, and extracts python-build-standalone — no Homebrew or user Python required.
    func ensureBaseInterpreter(onProgress: @Sendable (Double) -> Void) async throws -> String {
        if Self.isUsable(baseStandalonePythonPath) { onProgress(1.0); return baseStandalonePythonPath }
        guard let spec = standalone else {
            throw CompatibilityError.runtimeUnavailable(
                reason: "esh-managed Python provisioning currently supports Apple Silicon macOS")
        }
        let tmp = runtimeRootURL.appendingPathComponent("pbs-download.tar.gz")
        try? FileManager.default.removeItem(at: tmp)
        try await Self.download(spec.url, to: tmp, onProgress: { onProgress($0 * 0.8) })
        if let expected = spec.sha256 {
            let actual = try Self.sha256(of: tmp)
            guard actual == expected else {
                try? FileManager.default.removeItem(at: tmp)
                throw CompatibilityError.modelVerificationFailed("python-build-standalone checksum mismatch")
            }
        }
        onProgress(0.85)
        try? FileManager.default.removeItem(at: baseStandaloneDirURL)
        try FileManager.default.createDirectory(at: baseStandaloneDirURL, withIntermediateDirectories: true)
        try Self.untar(tmp, into: baseStandaloneDirURL)
        try? FileManager.default.removeItem(at: tmp)
        // A sandboxed app's download tags files with `com.apple.quarantine`; Gatekeeper then denies exec of
        // the extracted interpreter (EPERM). Strip it so the managed interpreter is runnable.
        Self.stripQuarantine(at: baseStandaloneDirURL)
        onProgress(1.0)
        guard Self.isUsable(baseStandalonePythonPath) else {
            throw CompatibilityError.runtimeUnavailable(reason: "extracted managed interpreter is not usable")
        }
        return baseStandalonePythonPath
    }

    /// The pinned build for this architecture (Apple Silicon), with env overrides. nil on unsupported arch.
    static func standaloneSpec() -> (url: URL, sha256: String?)? {
        #if arch(arm64)
        let env = ProcessInfo.processInfo.environment
        let urlString = env["ESH_PBS_URL"] ?? defaultStandaloneURL
        let sha = env["ESH_PBS_SHA256"] ?? defaultStandaloneSHA256
        guard let url = URL(string: urlString) else { return nil }
        return (url, sha.isEmpty ? nil : sha)
        #else
        return nil
        #endif
    }

    // MARK: Subprocess/IO helpers

    static func createVenv(base: String, venv: URL) throws {
        try? FileManager.default.removeItem(at: venv)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: base)
        p.arguments = ["-m", "venv", venv.path]
        let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "venv creation failed"
            throw CompatibilityError.runtimeUnavailable(reason: "esh-managed venv creation failed: \(String(msg.suffix(200)))")
        }
        // Best-effort pip bootstrap so dependency install is reliable; failure here surfaces later at pip time.
        let up = Process()
        up.executableURL = URL(fileURLWithPath: venv.appendingPathComponent("bin/python3").path)
        up.arguments = ["-m", "pip", "install", "--disable-pip-version-check", "--upgrade", "pip"]
        up.standardError = Pipe(); up.standardOutput = Pipe()
        try? up.run(); up.waitUntilExit()
    }

    static func download(_ url: URL, to dest: URL, onProgress: @Sendable (Double) -> Void) async throws {
        let tmp: URL, response: URLResponse
        // Bounded timeouts so provisioning fails fast with a typed error instead of hanging on a stalled
        // network (URLSession's default resource timeout is effectively unbounded).
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 600
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        do { (tmp, response) = try await session.download(from: url) }
        catch { throw CompatibilityError.runtimeUnavailable(reason: "managed interpreter download failed: \(error.localizedDescription)") }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CompatibilityError.runtimeUnavailable(reason: "managed interpreter download failed (HTTP \(http.statusCode))")
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        onProgress(1.0)
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while case let chunk = handle.readData(ofLength: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Remove `com.apple.quarantine` from a provisioned tree (recursive, no-op when absent) so a sandboxed
    /// app can exec the managed interpreter. Uses the in-process Darwin `removexattr` API rather than
    /// spawning `/usr/bin/xattr`: under the App Sandbox that subprocess (a Python-script wrapper) does not
    /// reliably clear the attribute, leaving the extracted base interpreter quarantined and non-executable
    /// (EPERM). A sandboxed app IS permitted to remove quarantine from files it owns via `removexattr`.
    /// `XATTR_NOFOLLOW` acts on symlinks themselves (e.g. `bin/python3`); other xattrs (`com.apple.provenance`)
    /// are left untouched. ENOATTR/errors are ignored (best-effort hygiene).
    static func stripQuarantine(at url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        func removeOne(_ path: String) {
            path.withCString { c in
                _ = "com.apple.quarantine".withCString { name in
                    removexattr(c, name, XATTR_NOFOLLOW)   // returns -1 with errno=ENOATTR when absent; ignored
                }
            }
        }
        removeOne(url.path)   // the root itself
        // Descendants: files, directories, and symlinks (not followed). The URL enumerator hides AppleDouble
        // `._*` sidecars, which is fine — quarantine lives on the real extracted files (binaries, dylibs).
        if let en = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [], errorHandler: nil) {
            for case let child as URL in en { removeOne(child.path) }
        }
    }

    static func untar(_ archive: URL, into dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-xzf", archive.path, "-C", dir.path]
        let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "extract failed"
            throw CompatibilityError.runtimeUnavailable(reason: "managed interpreter extract failed: \(String(msg.suffix(200)))")
        }
    }
}

#endif
