import Foundation
import EshCore
import EshRuntime

// M10 — production convenience so a host enables embedded GGUF without constructing a registry or knowing
// any backend type. This lives in EshLlamaCpp (which carries the llama.cpp dependency), so the portable
// EshRuntime/EshCore never link llama.cpp; a host that only wants Apple FM keeps using plain `EshRuntime()`.
public extension EshRuntime {
    /// An `EshRuntime` with Apple Foundation Models **and** the in-process llama.cpp GGUF backend wired,
    /// backed by the on-disk model store at `root`. Pair with `install(.qwen05B)` and a `.pinned(id)`
    /// request to run a managed GGUF model; Auto still prefers Apple FM (unchanged policy).
    ///
    /// The host never builds an `InferenceBackendRegistry`, constructs a backend, or handles model paths.
    static func withEmbeddedGGUF(config: LlamaCppConfig = .init(),
                                 root: PersistenceRoot = .default()) -> EshRuntime {
        let registry = InferenceBackendRegistry(backends: [
            .apple: AppleBackend(),
            .gguf: LlamaCppEmbeddedBackend(config: config),
        ])
        return EshRuntime(registry: registry,
                          installProvider: FileInstallProvider(root: root),
                          localModelManager: LocalModelManager(root: root))
    }
}
