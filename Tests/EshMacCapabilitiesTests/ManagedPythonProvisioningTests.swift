import Foundation
import Testing
import EshCore
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

    @Test func managedRuntimePathsResolveUnderAssetsRoot() {
        let assets = tmpRoot(); defer { try? FileManager.default.removeItem(at: assets) }
        let rt = ManagedPythonRuntime(root: PersistenceRoot(rootURL: assets))
        #expect(rt.venvPythonPath == assets.appendingPathComponent("runtime/py311/venv/bin/python3").path)
        #expect(rt.baseStandalonePythonPath == assets.appendingPathComponent("runtime/py311/base/python/bin/python3").path)
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

    @Test func hostAdoptsAnExistingManagedVenv() async {
        // A previously-provisioned managed venv at the canonical path must be adopted (reused across launches),
        // not re-provisioned. Fake interpreter reports 3.12 and "imports" every module → engine is ready.
        let assets = tmpRoot(); defer { try? FileManager.default.removeItem(at: assets) }
        makeFakePython(version: "3.12", at: assets.appendingPathComponent("runtime/py311/venv/bin/python3"))
        let host = EshManagedPythonHost(pythonPath: nil, bridgeScriptsDir: nil, root: PersistenceRoot(rootURL: assets))
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
        // Reuse: a second call adopts the just-provisioned venv (idempotent).
        let py2 = try await rt.provisionedPython(onProgress: { _ in })
        #expect(py2 == py)
    }
}
#endif
