import Foundation

/// Format-keyed registry of inference backends.
///
/// This type is **portable**: it holds *injected* backends and references no concrete backend type,
/// so it compiles on every Apple platform. The set of backends is decided by a platform assembly, not
/// hard-wired here — macOS wires MLX + GGUF + Apple (the `#if os(macOS)` default `init()` below); iOS
/// wires Apple Foundation Models only. Routing already constrains a request to the backends available
/// on the device, so a request never asks for a backend that was not injected.
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
    /// Default platform assembly.
    ///
    /// macOS wires MLX (also serves ONNX), llama.cpp GGUF, and Apple Foundation Models — these drive
    /// subprocess/Python/llama-server execution and are macOS-only by design. Every other Apple
    /// platform (iOS, visionOS, …) wires Apple Foundation Models only; no subprocess backend exists in
    /// an iOS build. This initializer is the single place the portable registry meets platform-specific
    /// backend construction.
    init() {
        #if os(macOS)
        self.init(backends: [
            .mlx: MLXBackend(),
            .gguf: LlamaCppBackend(),
            .apple: AppleBackend()
        ])
        #else
        self.init(backends: [
            .apple: AppleBackend()
        ])
        #endif
    }
}
