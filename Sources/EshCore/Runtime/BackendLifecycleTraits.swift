import Foundation

/// How a backend's runtimes behave across requests — the facts a host (and esh's own pool) needs to manage them
/// honestly. Reported per backend instance, because the same `BackendKind` can be wired differently (a one-shot vs
/// a persistent MLX backend; an embedded vs a spawned llama.cpp backend).
public struct BackendLifecycleTraits: Codable, Hashable, Sendable {
    /// Where prefix (KV) reuse across requests is available for this backend instance.
    public enum PrefixReuse: String, Codable, Hashable, Sendable {
        /// Every request prefills its whole prompt.
        case none
        /// Token-exact prefix reuse persisted between calls (MLX `tokens` mode: a state file + KV sidecar).
        case persistedTokens = "persisted-tokens"
        /// Prefix KV kept live in a resident worker and matched by content (MLX `live`, persistent worker only).
        case live
        /// Token-exact prefix KV kept in the loaded runtime between requests (embedded llama.cpp with
        /// `LlamaCppConfig.reusePromptPrefix`), the in-process equivalent of llama-server's prompt cache.
        case residentTokens = "resident-tokens"
        /// Managed by the system (Apple Foundation Models); esh has no control or visibility.
        case systemManaged = "system-managed"
    }

    /// `weightsResident` when a loaded runtime keeps the weights in memory until `unload()` (worth pooling);
    /// `handleCached` when each request reloads them anyway.
    public var residency: RuntimeResidency
    /// Runs inside the host process (no child process, no Python, no localhost server). Required on iOS.
    public var inProcess: Bool
    public var prefixReuse: PrefixReuse
    /// Requests to one loaded runtime run one at a time (a second request waits for the first).
    public var serializesRequestsPerModel: Bool
    /// The KV/context memory a request can use is fixed when the runtime is loaded (llama.cpp `n_ctx`), so a long
    /// request overflows (typed error) instead of growing memory. When false, esh's KV-growth guard judges each
    /// request before generation.
    public var contextBoundedAtLoad: Bool
    /// Cancelling the consuming task stops work inside prefill too, not only between generated tokens.
    public var cancelsDuringPrefill: Bool
    /// The platforms where this backend can run at all.
    public var supportsIOS: Bool

    public init(residency: RuntimeResidency, inProcess: Bool, prefixReuse: PrefixReuse,
                serializesRequestsPerModel: Bool, contextBoundedAtLoad: Bool, cancelsDuringPrefill: Bool,
                supportsIOS: Bool) {
        self.residency = residency
        self.inProcess = inProcess
        self.prefixReuse = prefixReuse
        self.serializesRequestsPerModel = serializesRequestsPerModel
        self.contextBoundedAtLoad = contextBoundedAtLoad
        self.cancelsDuringPrefill = cancelsDuringPrefill
        self.supportsIOS = supportsIOS
    }

    /// Conservative default for a backend that does not declare its traits: nothing is assumed.
    public static let unspecified = BackendLifecycleTraits(
        residency: .handleCached, inProcess: false, prefixReuse: .none, serializesRequestsPerModel: true,
        contextBoundedAtLoad: false, cancelsDuringPrefill: false, supportsIOS: false)
}

/// Optional conformance: a backend that knows its own lifecycle traits. Backends that don't conform report
/// `BackendLifecycleTraits.unspecified` (see `InferenceBackend.lifecycleTraits`).
public protocol BackendLifecycleDescribing {
    var lifecycleTraits: BackendLifecycleTraits { get }
}

public extension InferenceBackend {
    /// This backend instance's lifecycle traits, or `.unspecified` when it does not declare them.
    var lifecycleTraits: BackendLifecycleTraits {
        (self as? BackendLifecycleDescribing)?.lifecycleTraits ?? .unspecified
    }
}

/// KV-cache growth guard shared by every inference entry point (`ExternalInferenceService` behind `esh serve`/`infer`
/// and the public `EshRuntime` SDK facade), so there is one policy, not two.
///
/// Before generating on a backend whose context is NOT bounded at load (MLX), estimate the KV the request can add —
/// the whole prompt plus every allowed new token, at the model's real bytes/token from `config.json` — and judge it:
///   * with a warm pool: `RuntimeLifecycleManager.ensureHeadroom` (releases idle caches, evicts idle models LRU,
///     never touches active requests, then refuses with `insufficientMemoryForContext`);
///   * without a pool (one-shot): the model is not loaded yet, so weights + growth are judged together.
/// GGUF needs no guard here: its KV buffer is fixed at load (`n_ctx`) and an overflowing request fails typed.
public enum ContextGrowthGuard {
    public static func check(install: ModelInstall, promptCharacters: Int, messageCount: Int, maxTokens: Int,
                             pool: RuntimeLifecycleManager?, weightsNotYetLoaded: Bool,
                             gate: RuntimeLifecycleManager.GrowthGate = RuntimeLifecycleManager.liveGrowthGate) async throws {
        guard install.spec.backend == .mlx,
              let perToken = KVCacheEstimator.bytesPerToken(modelDirectory: URL(fileURLWithPath: install.installPath))
        else { return }
        let growth = KVCacheEstimator.growthBytes(bytesPerToken: perToken, promptCharacters: promptCharacters,
                                                  messages: messageCount, maxTokens: maxTokens)
        if let pool {
            try await pool.ensureHeadroom(forAdditionalBytes: growth, modelID: install.id)
            return
        }
        let growthGB = Double(growth) / 1_073_741_824
        let weightsGB = weightsNotYetLoaded ? ModelLoadSafetyGate.requiredPeakGB(for: install) : 0
        if case let .gated(reason, _, _) = gate(growthGB + weightsGB) {
            throw RuntimeLifecycleError.insufficientMemoryForContext(modelID: install.id, neededGB: growthGB, reason: reason)
        }
    }
}
