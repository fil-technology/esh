import Foundation
import EshCore

// macOS backend assembly (M9).
//
// The portable `InferenceBackendRegistry()` default (in EshCore) wires Apple Foundation Models only, so
// the portable core references no concrete macOS backend type. This extension — which lives in the
// macOS-only `EshMacRuntime` target — is the single place the full macOS execution assembly is built:
// MLX (also serving ONNX), the spawned llama.cpp GGUF server, and Apple Foundation Models. The macOS
// CLI (`esh`) injects this assembly; iOS never links this target.
public extension InferenceBackendRegistry {
    /// The macOS execution assembly: MLX + spawned llama.cpp GGUF + Apple Foundation Models.
    ///
    /// `.onnx` resolves through the MLX backend (see `resolve(_:)`), preserving prior macOS behavior. An
    /// embedded in-process GGUF backend (`EshLlamaCpp`) is host-injected separately when present and is
    /// not part of this default.
    static func macOS() -> InferenceBackendRegistry {
        InferenceBackendRegistry(backends: [
            .mlx: MLXBackend(),
            .gguf: LlamaCppBackend(),
            .apple: AppleBackend()
        ])
    }
}
