import Foundation

/// Format-keyed registry of inference backends.
///
/// This type is **portable**: it holds *injected* backends and references no concrete backend type,
/// so it compiles on every Apple platform. The set of backends is decided by a platform assembly, not
/// hard-wired here — the portable default `init()` below wires Apple Foundation Models only; the macOS
/// assembly (MLX + spawned GGUF + Apple) lives in `EshMacRuntime.InferenceBackendRegistry.macOS()` and
/// is injected by the macOS CLI. Routing already constrains a request to the backends available on the
/// device, so a request never asks for a backend that was not injected.
public struct InferenceBackendRegistry: Sendable {
    private let backends: [BackendKind: any InferenceBackend]

    /// Inject the backends available on this platform.
    ///
    /// `.onnx` falls back to the `.mlx` backend when one is registered (ONNX models execute through the
    /// MLX runtime), preserving prior macOS behavior.
    public init(backends: [BackendKind: any InferenceBackend]) {
        self.backends = backends
    }

    /// The backend registered for a model format, or `nil` when this platform provides none for it.
    public func resolve(_ kind: BackendKind) -> (any InferenceBackend)? {
        if let backend = backends[kind] { return backend }
        if kind == .onnx { return backends[.mlx] }
        return nil
    }

    /// The backend for an install's declared format.
    ///
    /// Precondition: the format's backend is registered on this platform. Routing guarantees this
    /// (candidates are filtered by availability before selection), so a miss is a programming error in
    /// the assembly/routing wiring, not a user-reachable runtime path.
    public func backend(for install: ModelInstall) -> any InferenceBackend {
        guard let backend = resolve(install.spec.backend) else {
            preconditionFailure(
                "No inference backend registered for '\(install.spec.backend.rawValue)' on this platform. "
                + "Check the platform backend assembly (see InferenceBackendRegistry)."
            )
        }
        return backend
    }
}

public extension InferenceBackendRegistry {
    /// Default **portable** assembly: Apple Foundation Models only.
    ///
    /// EshCore carries no macOS-only execution infrastructure (M9), so the portable default wires the
    /// Apple backend, which is available on every Apple platform. macOS execution backends (MLX, spawned
    /// llama.cpp GGUF) live in `EshMacRuntime` and are assembled by `InferenceBackendRegistry.macOS()`
    /// there; the macOS CLI injects that assembly. An embedded GGUF backend (`EshLlamaCpp`) is likewise
    /// host-injected. This keeps the single portable registry free of any concrete macOS backend type.
    init() {
        self.init(backends: [
            .apple: AppleBackend()
        ])
    }
}
