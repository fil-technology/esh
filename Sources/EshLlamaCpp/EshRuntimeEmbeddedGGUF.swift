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
    ///
    /// `lifecycle`: `.oneShot` (default) loads the GGUF model per call and frees it when the call ends;
    /// `.managed()` keeps it resident in esh's warm pool across calls (chat apps) — call `shutdown()` on teardown.
    static func withEmbeddedGGUF(config: LlamaCppConfig = .init(),
                                 root: PersistenceRoot = .default(),
                                 lifecycle: EshRuntimeLifecycle = .oneShot) -> EshRuntime {
        let registry = InferenceBackendRegistry(backends: [
            .apple: AppleBackend(),
            .gguf: LlamaCppEmbeddedBackend(config: config),
        ])
        return EshRuntime(registry: registry,
                          installProvider: FileInstallProvider(root: root),
                          localModelManager: LocalModelManager(root: root),
                          lifecycle: lifecycle)
    }

    /// Like `withEmbeddedGGUF` but also wires the portable multimodal (UCMR) capability providers (OCR,
    /// SVG, Web, Code, and text) behind the `execute`/`stream(ExecutionRequest)` facade — text capabilities
    /// run on Apple FM or the embedded GGUF model. Use this when the app wants Create/OCR in addition to
    /// chat. (Async because provider assembly attaches to the constructed runtime.)
    static func makeWithEmbeddedGGUF(config: LlamaCppConfig = .init(),
                                     root: PersistenceRoot = .default(),
                                     lifecycle: EshRuntimeLifecycle = .oneShot) async -> EshRuntime {
        await EshRuntime.makeDefault(
            backends: [.apple: AppleBackend(), .gguf: LlamaCppEmbeddedBackend(config: config)],
            root: root,
            installProvider: FileInstallProvider(root: root),
            localModelManager: LocalModelManager(root: root),
            lifecycle: lifecycle)
    }
}
