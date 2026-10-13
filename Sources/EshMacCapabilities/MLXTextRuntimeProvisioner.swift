import Foundation
import EshCore

#if os(macOS)

/// The resolved, ready-to-use runtime facing paths for the MLX **text** backend: an esh-managed Python
/// interpreter that has `mlx` + `mlx_lm` installed, and the esh-shipped `mlx_vlm_bridge.py` that implements
/// the `mlx-serve` worker protocol. A consumer (the macOS CLI assembly, a validation harness, or an app's
/// runtime builder) feeds these into `MLXBridgeConfiguration` so `MLXBackend` drives the managed venv — it
/// never asks the consumer for a Python path, a venv, or a bridge script.
public struct MLXTextRuntimeProvision: Sendable, Equatable {
    /// Absolute path to the esh-managed venv interpreter with the MLX text runtime installed.
    public let pythonExecutablePath: String
    /// Absolute path to the esh-shipped `mlx_vlm_bridge.py`.
    public let bridgeScriptPath: String
    public init(pythonExecutablePath: String, bridgeScriptPath: String) {
        self.pythonExecutablePath = pythonExecutablePath
        self.bridgeScriptPath = bridgeScriptPath
    }
}

/// esh-owned provisioning of the MLX **text** runtime, layered on the same managed Python infrastructure the
/// compatibility engines use (`ManagedPythonRuntime` + `EshManagedPythonHost`). This is the stable,
/// runtime-facing Phase-2 interface:
///
///  - **Isolated:** uses esh's relocatable python-build-standalone venv on the INTERNAL state root — never a
///    global interpreter, never Homebrew, never Anaconda.
///  - **No duplicate model downloads:** this only ensures Python *packages* (`mlx`, `mlx_lm`); model weights
///    are resolved separately from the model store by the backend.
///  - **Honest state:** `probe()` reports readiness without mutating anything; `ensure()` provisions +
///    installs and reports progress, surfacing a typed `CompatibilityError` on failure.
///
/// It deliberately returns plain paths (`MLXTextRuntimeProvision`) rather than an `MLXBridgeConfiguration`, so
/// this module stays decoupled from `EshMLXText`; the consumer that links both builds the configuration.
public enum MLXTextRuntimeProvisioner {
    /// Python import names probed to decide whether the text runtime is ready.
    public static let requiredModules = ["mlx", "mlx_lm"]
    /// pip package(s) that provide them. `mlx-lm` pulls a compatible `mlx` as a dependency; both are listed so
    /// a repair that finds only `mlx` missing can reinstall it directly.
    static let pipPackages = ["mlx", "mlx-lm"]

    /// The deterministic managed paths for the MLX text runtime, resolved with **cheap FS checks only** (no
    /// subprocess, no import probe) — safe to call on a hot path such as runtime assembly. Returns the paths
    /// when the managed venv interpreter and the esh-shipped bridge both exist on disk, else `nil`. This does
    /// NOT guarantee `mlx_lm` is importable (that is verified by `probe()` / enforced at first model load and
    /// healed by `ensure()`); it only decides whether `.mlx` can be meaningfully registered without blocking.
    public static func resolvedPaths(root: PersistenceRoot = .default()) -> MLXTextRuntimeProvision? {
        let python = ManagedPythonRuntime(root: root).venvPythonPath
        guard FileManager.default.isExecutableFile(atPath: python) else { return nil }
        guard let bridgeDir = EshManagedPythonHost.bundledBridgeDir() else { return nil }
        let bridge = bridgeDir + "/mlx_vlm_bridge.py"
        guard FileManager.default.fileExists(atPath: bridge) else { return nil }
        return MLXTextRuntimeProvision(pythonExecutablePath: python, bridgeScriptPath: bridge)
    }

    /// Is the MLX text runtime ready RIGHT NOW without provisioning? Adopts an already-provisioned managed
    /// venv and probes the modules against it. Never downloads or installs. `nil` bridge dir / unprovisioned
    /// venv / missing module all return `false` — the honest "not ready yet" answer.
    public static func probe(root: PersistenceRoot = .default()) -> Bool {
        let python = ManagedPythonRuntime(root: root).venvPythonPath
        guard ManagedPythonRuntime.isUsable(python) else { return false }
        guard EshManagedPythonHost.bundledBridgeDir() != nil else { return false }
        for module in requiredModules where EshManagedPythonHost.runProbe(python: python, module: module).code != 0 {
            return false
        }
        return true
    }

    /// Provision (adopt-or-create) the managed venv, ensure `mlx` + `mlx_lm` are installed into it, resolve
    /// the esh-shipped bridge script, and return the runtime-facing paths. Idempotent: an already-ready
    /// runtime returns immediately after a cheap probe. Progress spans provisioning (venv) + install (pip).
    ///
    /// Never bypasses memory guards — this only prepares the Python runtime; the backend's live memory
    /// preflight still gates every model load at generation time.
    public static func ensure(
        root: PersistenceRoot = .default(),
        onProgress: @Sendable @escaping (Double) -> Void = { _ in }
    ) async throws -> MLXTextRuntimeProvision {
        guard let bridgeDir = EshManagedPythonHost.bundledBridgeDir() else {
            throw CompatibilityError.runtimeUnavailable(
                reason: "esh MLX text bridge script is missing from the SDK bundle")
        }
        let bridgeScript = bridgeDir + "/mlx_vlm_bridge.py"
        guard FileManager.default.fileExists(atPath: bridgeScript) else {
            throw CompatibilityError.runtimeUnavailable(
                reason: "esh MLX text bridge script not found at \(bridgeScript)")
        }

        // Adopt-or-provision the managed interpreter (python-build-standalone venv, no Homebrew/Anaconda).
        let runtime = ManagedPythonRuntime(root: root)
        let python = try await runtime.provisionedPython(onProgress: { onProgress($0 * 0.5) })

        // Install only the modules actually missing, so a ready runtime is a no-op and a repair is minimal.
        let missing = requiredModules.filter { EshManagedPythonHost.runProbe(python: python, module: $0).code != 0 }
        if missing.isEmpty {
            onProgress(1.0)
        } else {
            try EshManagedPythonHost.pipInstall(
                python: python, packages: pipPackages,
                onProgress: { onProgress(0.5 + $0 * 0.5) })
            // Verify the install actually satisfies the imports — never report ready on a half-install.
            let stillMissing = requiredModules.filter { EshManagedPythonHost.runProbe(python: python, module: $0).code != 0 }
            guard stillMissing.isEmpty else {
                throw CompatibilityError.dependencyInstallationFailed(
                    reason: "MLX text runtime modules still missing after install: \(stillMissing.joined(separator: ", "))")
            }
            onProgress(1.0)
        }

        return MLXTextRuntimeProvision(pythonExecutablePath: python, bridgeScriptPath: bridgeScript)
    }
}

#endif
