import Foundation
import Testing
import EshCore
import Darwin   // setxattr / getxattr — exercise the real in-process quarantine strip
@testable import EshRuntime
@testable import EshMacCapabilities

// Coverage for esh-owned managed-Python provisioning (the rc.9 targeted fix): a consumer supplies no Python
// path, venv, bridge, or Homebrew — esh adopts an existing compatible runtime or provisions one, resolves
// its shipped bridge from the bundle, reports honest states, and persists/reuses across launches.
#if os(macOS)
@Suite struct ManagedPythonProvisioningTests {
    private func tmpRoot() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
    }
    /// A fake interpreter: prints a chosen "major.minor" for the version probe and exits 0 for every other
    /// invocation (module import probes, pip). Lets us test adoption/version logic without a real Python.
    @discardableResult
    private func makeFakePython(version: String, at path: URL) -> String {
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        case "$*" in
          *version_info*) echo "\(version)" ;;
          *) : ;;
        esac
        exit 0
        """
        try? script.write(to: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path.path
    }
    private func music() -> CompatibilityEngineManifest { MacCapabilities.manifests().first { $0.id == .imageGeneration }! }

    @Test func managedRuntimeStaysInternalWhileModelsStayExternal() {
        // rc.10 Fix B: the managed interpreter/venv live on the INTERNAL state root (rootURL), while model
        // weights + HF caches remain on the EXTERNAL assets root. exFAT/xattr AppleDouble issues and the
        // PersistenceRoot contract both require this separation.
        let internalRoot = tmpRoot(); defer { try? FileManager.default.removeItem(at: internalRoot) }
        let externalRoot = tmpRoot(); defer { try? FileManager.default.removeItem(at: externalRoot) }
        let root = PersistenceRoot(stateRootURL: internalRoot, assetsRootURL: externalRoot)
        let rt = ManagedPythonRuntime(root: root)
        // Runtime → internal.
        #expect(rt.venvPythonPath == internalRoot.appendingPathComponent("runtime/py311/venv/bin/python3").path)
        #expect(rt.baseStandalonePythonPath == internalRoot.appendingPathComponent("runtime/py311/base/python/bin/python3").path)
        #expect(rt.runtimeRootURL.path.hasPrefix(internalRoot.path))
        #expect(!rt.runtimeRootURL.path.hasPrefix(externalRoot.path))
        // Models / HF cache → external (unchanged routing).
        #expect(root.cachesURL.path.hasPrefix(externalRoot.path))
        #expect(root.pythonHFCacheURL(family: "image").path.hasPrefix(externalRoot.path))
        #expect(root.modelsURL.path.hasPrefix(externalRoot.path))
    }

    // Darwin xattr helpers (in-process, matching what the sandbox-safe strip uses).
    private func setQuarantine(_ path: String) {
        let v = Array("0081;00000000;Test;".utf8)
        _ = path.withCString { c in "com.apple.quarantine".withCString { n in
            setxattr(c, n, v, v.count, 0, XATTR_NOFOLLOW) } }
    }
    private func hasQuarantine(_ path: String) -> Bool {
        path.withCString { c in "com.apple.quarantine".withCString { n in
            getxattr(c, n, nil, 0, 0, XATTR_NOFOLLOW) >= 0 } }
    }

    @Test func stripQuarantineRemovesTheAttributeInProcess() throws {
        // rc.11 Fix: the strip must work IN-PROCESS (the /usr/bin/xattr subprocess was a silent no-op under
        // the App Sandbox). Set com.apple.quarantine via setxattr on a nested tree, strip, assert getxattr
        // reports it gone (ENOATTR) on the root, a nested file, AND a symlink (XATTR_NOFOLLOW).
        let dir = tmpRoot(); defer { try? FileManager.default.removeItem(at: dir) }
        let binDir = dir.appendingPathComponent("base/python/bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let real = binDir.appendingPathComponent("python3.11")
        try Data("#!/bin/sh\n".utf8).write(to: real)
        let link = binDir.appendingPathComponent("python3")
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        setQuarantine(dir.path); setQuarantine(real.path); setQuarantine(link.path)
        #expect(hasQuarantine(real.path))   // sanity: it was set
        ManagedPythonRuntime.stripQuarantine(at: dir)
        #expect(!hasQuarantine(dir.path))
        #expect(!hasQuarantine(real.path))
        #expect(!hasQuarantine(link.path))
    }

    @Test func versionDetectionAndUsability() {
        let dir = tmpRoot(); defer { try? FileManager.default.removeItem(at: dir) }
        let ok = makeFakePython(version: "3.12", at: dir.appendingPathComponent("ok/python3"))
        let old = makeFakePython(version: "3.9", at: dir.appendingPathComponent("old/python3"))
        #expect(ManagedPythonRuntime.pythonVersion(ok)?.0 == 3 && ManagedPythonRuntime.pythonVersion(ok)?.1 == 12)
        #expect(ManagedPythonRuntime.isUsable(ok) == true)
        #expect(ManagedPythonRuntime.isUsable(old) == false)         // 3.9 < 3.11
        #expect(ManagedPythonRuntime.isUsable("/no/such/python") == false)
        #expect(ManagedPythonRuntime.pythonVersion("/no/such/python") == nil)
    }

    @Test func standaloneSpecIsPinnedOnAppleSilicon() {
        let spec = ManagedPythonRuntime.standaloneSpec()
        #if arch(arm64)
        #expect(spec != nil)
        #expect(spec?.sha256 == ManagedPythonRuntime.defaultStandaloneSHA256)
        #expect(spec?.url.absoluteString.contains("python-build-standalone") == true)
        #else
        #expect(spec == nil)
        #endif
    }

    @Test func bundledBridgeResolvesFromPackage() {
        // esh ships the bridge; the consumer never passes a bridge dir.
        let dir = EshManagedPythonHost.bundledBridgeDir()
        #expect(dir != nil)
        if let dir {
            #expect(FileManager.default.fileExists(atPath: dir + "/mlx_vlm_bridge.py"))
            #expect(FileManager.default.fileExists(atPath: dir + "/triattention_runtime.py"))
        }
    }

    @Test func hostReportsRequiresDownloadWhenUnprovisioned() async {
        let assets = tmpRoot(); defer { try? FileManager.default.removeItem(at: assets) }
        let host = EshManagedPythonHost(pythonPath: nil, bridgeScriptsDir: nil, root: PersistenceRoot(rootURL: assets))
        let state = await host.inspect(music())
        guard case .requiresDownload = state else { Issue.record("expected .requiresDownload, got \(state)"); return }
    }

    @Test func hostAdoptsAnExistingInternalManagedVenv() async {
        // A previously-provisioned managed venv at the canonical INTERNAL path must be adopted (reused across
        // launches), not re-provisioned — even when a separate external assets root is configured. Fake
        // interpreter reports 3.12 and "imports" every module → engine is ready.
        let internalRoot = tmpRoot(); defer { try? FileManager.default.removeItem(at: internalRoot) }
        let externalRoot = tmpRoot(); defer { try? FileManager.default.removeItem(at: externalRoot) }
        makeFakePython(version: "3.12", at: internalRoot.appendingPathComponent("runtime/py311/venv/bin/python3"))
        let host = EshManagedPythonHost(pythonPath: nil, bridgeScriptsDir: nil,
                                        root: PersistenceRoot(stateRootURL: internalRoot, assetsRootURL: externalRoot))
        let state = await host.inspect(music())
        #expect(state == .ready)
    }

    @Test func provisioningFailureIsTypedError() async {
        // No adoptable venv + an unreachable base build → a typed CompatibilityError, never a raw error.
        let assets = tmpRoot(); defer { try? FileManager.default.removeItem(at: assets) }
        let bad = URL(string: "file:///nonexistent-\(UUID().uuidString).tar.gz")!
        let rt = ManagedPythonRuntime(root: PersistenceRoot(rootURL: assets), standalone: (bad, nil))
        await #expect(throws: CompatibilityError.self) {
            _ = try await rt.provisionedPython(onProgress: { _ in })
        }
    }

    @Test func adoptedVenvProvisioningIsIdempotent() async throws {
        // With a usable venv already present, provisionedPython returns it without touching the network/base.
        let assets = tmpRoot(); defer { try? FileManager.default.removeItem(at: assets) }
        let venvPy = makeFakePython(version: "3.12", at: assets.appendingPathComponent("runtime/py311/venv/bin/python3"))
        let bad = URL(string: "file:///nonexistent-\(UUID().uuidString).tar.gz")!  // would fail if provisioning ran
        let rt = ManagedPythonRuntime(root: PersistenceRoot(rootURL: assets), standalone: (bad, nil))
        let resolved = try await rt.provisionedPython(onProgress: { _ in })
        #expect(resolved == venvPy)
    }

    // Integration (opt-in): the real clean-machine provision — download python-build-standalone, verify,
    // extract, create a real venv. Off by default (network + ~18 MB). Enable with ESH_RUN_COMPAT_INTEGRATION=1.
    @Test func integrationProvisionsCleanManagedRuntime() async throws {
        guard ProcessInfo.processInfo.environment["ESH_RUN_COMPAT_INTEGRATION"] == "1" else { return }
        let assets = tmpRoot(); defer { try? FileManager.default.removeItem(at: assets) }
        let rt = ManagedPythonRuntime(root: PersistenceRoot(rootURL: assets))
        let py = try await rt.provisionedPython(onProgress: { _ in })
        #expect(ManagedPythonRuntime.isUsable(py))
        #expect(py == rt.venvPythonPath)
        // The invariant the rc.12 prevention guarantees: the app-created tarball → extracted tree carries NO
        // com.apple.quarantine. Trivially true off-sandbox; the real regression guard is a sandboxed CI run.
        #expect(!hasQuarantine(rt.baseStandalonePythonPath))
        #expect(!hasQuarantine(py))
        // Reuse: a second call adopts the just-provisioned venv (idempotent).
        let py2 = try await rt.provisionedPython(onProgress: { _ in })
        #expect(py2 == py)
    }
}
#endif
