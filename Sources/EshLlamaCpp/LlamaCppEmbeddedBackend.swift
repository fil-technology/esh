import Foundation
import EshCore
import esh_llama

// esh M7 — embedded GGUF backend. Runs GGUF models FULLY IN-PROCESS via the llama.cpp C API (Metal on
// device). No Process, no localhost server, no Python. Implements the existing EshCore contracts so
// EshRuntime's router/registry drives it exactly like any other backend. Isolated in its own target so the
// C/C++ dependency never enters the portable EshCore.

/// Configuration for the embedded llama.cpp runtime.
public struct LlamaCppConfig: Sendable {
    /// Bounded context window (tokens). Mobile: keep small. 0 = model default.
    public var contextTokens: Int
    /// Layers to offload to the GPU (Metal). Negative/large = all. 0 = CPU only.
    public var gpuLayers: Int
    /// Token-exact prefix reuse across requests on the same loaded runtime (what llama-server's prompt cache does):
    /// a request keeps the KV of the longest common token prefix with the previous request and decodes only the
    /// rest. Only useful when the runtime stays loaded (`EshRuntimeLifecycle.managed`). Off by default: the reused
    /// prefix is decoded in different batches than a full prefill, so greedy output can differ in rare near-ties
    /// (see docs/research/managed-sdk-runtime-2026-11.md). Requests stay isolated either way — the KV beyond the
    /// common prefix is always removed.
    public var reusePromptPrefix: Bool
    public init(contextTokens: Int = 2048, gpuLayers: Int = 999, reusePromptPrefix: Bool = false) {
        self.contextTokens = contextTokens
        self.gpuLayers = gpuLayers
        self.reusePromptPrefix = reusePromptPrefix
    }
}

public enum LlamaCppError: Error, LocalizedError, Sendable {
    case modelFileMissing(String)
    case modelLoadFailed(String)
    case contextInitFailed
    case tokenizeFailed
    case decodeFailed(Int32)
    /// The prompt alone needs at least as many tokens as the loaded context window holds.
    case contextOverflow(promptTokens: Int, contextTokens: Int)
    /// The runtime was unloaded; load it again to generate.
    case unloaded
    public var errorDescription: String? {
        switch self {
        case let .modelFileMissing(p): return "GGUF model file not found at \(p)"
        case let .modelLoadFailed(p): return "llama.cpp failed to load the GGUF model at \(p)"
        case .contextInitFailed: return "llama.cpp failed to create a context"
        case .tokenizeFailed: return "llama.cpp failed to tokenize the prompt"
        case let .decodeFailed(code): return "llama.cpp decode failed (code \(code))"
        case let .contextOverflow(p, n):
            return "The prompt is \(p) tokens but the model's context window is \(n) tokens. Shorten the conversation or load the model with a larger LlamaCppConfig.contextTokens."
        case .unloaded: return "The llama.cpp runtime was unloaded."
        }
    }
}

/// The in-process GGUF backend. `.gguf` kind, like the macOS llama-server backend — but this one is
/// embedded (no subprocess) and is the iOS path.
public struct LlamaCppEmbeddedBackend: InferenceBackend, @unchecked Sendable {
    public let kind: BackendKind = .gguf
    public let runtimeVersion: String = "llama.cpp-embedded"
    private let config: LlamaCppConfig
    private let resolveModelPath: @Sendable (ModelInstall) -> String?

    /// `resolveModelPath` maps an install to a local GGUF file path. The default resolves the actual file:
    /// it prefers `spec.localPath` (set by the local model manager), and if `installPath` is a directory
    /// (as the model store reports it), it appends the managed `model.gguf` filename.
    public init(config: LlamaCppConfig = .init(),
                resolveModelPath: @escaping @Sendable (ModelInstall) -> String? = Self.defaultResolveModelPath) {
        self.config = config
        self.resolveModelPath = resolveModelPath
    }

    public static let defaultResolveModelPath: @Sendable (ModelInstall) -> String? = { install in
        let fm = FileManager.default
        // The model store may report either the model file or the install directory (and may rewrite
        // spec.localPath to the directory on relocation). Resolve to the actual .gguf file for each
        // candidate: a file → use it; a directory → the managed `model.gguf` inside it.
        for candidate in [install.spec.localPath, install.installPath].compactMap({ $0 }).filter({ !$0.isEmpty }) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: candidate, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let file = candidate + "/model.gguf"
                if fm.fileExists(atPath: file) { return file }
            } else {
                return candidate
            }
        }
        return nil
    }

    public func capabilityReport(for install: ModelInstall) -> BackendCapabilityReport {
        guard let path = resolveModelPath(install), FileManager.default.fileExists(atPath: path) else {
            return BackendCapabilityReport(
                backend: kind, runtimeVersion: runtimeVersion, ready: false,
                supportedFeatures: [],
                unavailableFeatures: [.init(feature: .directInference, reason: "GGUF model file is not present on this device.")],
                warnings: ["GGUF model file is not present on this device."])
        }
        return BackendCapabilityReport(
            backend: kind, runtimeVersion: runtimeVersion, ready: true,
            supportedFeatures: [.directInference, .tokenStreaming])
    }

    public func loadRuntime(for install: ModelInstall) async throws -> BackendRuntime {
        guard let path = resolveModelPath(install) else { throw LlamaCppError.modelFileMissing("<unresolved>") }
        guard FileManager.default.fileExists(atPath: path) else { throw LlamaCppError.modelFileMissing(path) }
        let ctx = try await LlamaContext.make(modelPath: path, config: config)
        return LlamaCppEmbeddedRuntime(modelID: install.id, context: ctx)
    }

    public func makeCompatibilityChecker(for install: ModelInstall) -> CompatibilityChecking {
        LlamaCppCompatibilityChecker()
    }
}

private struct LlamaCppCompatibilityChecker: CompatibilityChecking, Sendable {
    func validate(manifest: CacheManifest) throws {
        throw CompatibilityIssue(reason: "The embedded llama.cpp backend does not support esh prompt caches.")
    }
}

/// `BackendRuntime` over an actor-owned llama.cpp context. Streaming, cooperative cancellation, honest
/// metrics, explicit unload.
public final class LlamaCppEmbeddedRuntime: BackendRuntime, @unchecked Sendable {
    public let backend: BackendKind = .gguf
    public let modelID: String
    private let context: LlamaContext
    private let metricsBox = MetricsBox()

    init(modelID: String, context: LlamaContext) {
        self.modelID = modelID
        self.context = context
    }

    public var metrics: Metrics { get async { await metricsBox.value } }

    public func prepare(session: ChatSession) async throws {}

    public func generate(session: ChatSession, config: GenerationConfig) -> AsyncThrowingStream<String, Error> {
        let context = self.context
        let box = self.metricsBox
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let prompt = await context.formatPrompt(session: session)
                    let result = try await context.generate(
                        prompt: prompt, config: config,
                        onToken: { piece in continuation.yield(piece) },
                        isCancelled: { Task.isCancelled }
                    )
                    await box.set(result)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func exportRuntimeCache() async throws -> CacheSnapshot { throw StoreError.invalidManifest("embedded llama.cpp does not support cache export.") }
    public func importRuntimeCache(_ snapshot: CacheSnapshot) async throws { throw StoreError.invalidManifest("embedded llama.cpp does not support cache import.") }
    public func validateCacheCompatibility(_ manifest: CacheManifest) async throws { throw CompatibilityIssue(reason: "embedded llama.cpp does not support prompt caches.") }
    public func unload() async { await context.unload() }
}

/// Thread-safe metrics holder (the runtime is `@unchecked Sendable`; metrics are actor-guarded).
private actor MetricsBox {
    private(set) var value = Metrics()
    func set(_ m: Metrics) { value = m }
}

// MARK: - llama.cpp context (actor-serialized C interop)

/// Exclusive owner of one native llama model + context. Freed deterministically: explicitly by `free()` (the runtime's
/// `unload()`), or by `deinit` when the last reference goes away — a host that never calls `unload()`, a dropped or
/// cancelled one-shot, or a pool eviction. Before this owner existed nothing freed a context that wasn't explicitly
/// unloaded, and every `EshRuntime.generate` leaked one (~60 MB measured with a 0.5B Q4 model). `free()` is
/// idempotent. Only touched from the owning `LlamaContext` actor (serialized) or from `deinit` (exclusive).
final class LlamaNativeHandles: @unchecked Sendable {
    private(set) var model: OpaquePointer?
    private(set) var ctx: OpaquePointer?
    init(model: OpaquePointer, ctx: OpaquePointer) { self.model = model; self.ctx = ctx }
    func free() {
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
        ctx = nil; model = nil
    }
    deinit { free() }
}

actor LlamaContext {
    private let handles: LlamaNativeHandles
    private var model: OpaquePointer? { handles.model }
    private var ctx: OpaquePointer? { handles.ctx }
    private var vocab: OpaquePointer?
    private let modelBytes: UInt64
    private let reusePromptPrefix: Bool
    /// Exactly the tokens whose KV is in sequence 0, in position order (prefix reuse bookkeeping). Updated only after
    /// a successful decode, so it never claims KV that isn't there.
    private var kvTokens: [llama_token] = []

    private init(model: OpaquePointer, ctx: OpaquePointer, vocab: OpaquePointer, modelBytes: UInt64, reusePromptPrefix: Bool) {
        self.handles = LlamaNativeHandles(model: model, ctx: ctx)
        self.vocab = vocab
        self.modelBytes = modelBytes
        self.reusePromptPrefix = reusePromptPrefix
    }

    /// `llama_backend_init` is process-global; run it once rather than on every model load.
    private static let backendInit: Void = { llama_backend_init() }()

    static func make(modelPath: String, config: LlamaCppConfig) async throws -> LlamaContext {
        // Clean-shutdown fix: ggml-metal's residency-set keep-alive (180 s) leaves Metal buffers resident, so at
        // process exit the global device destructor trips `GGML_ASSERT([rsets->data count] == 0)` in
        // `ggml_metal_device_free` (`__cxa_finalize`) — a native abort AFTER inference completes (reproduced with
        // any GGUF model). Disabling residency sets makes termination clean. Measured throughput impact is
        // negligible (~2% on a 1.5B Q4; 48.1 vs 49.2 tok/s). `overwrite = 0` so a host that has deliberately set
        // this env (e.g. to keep residency for a memory-tight large model, accepting the exit abort) wins.
        setenv("GGML_METAL_NO_RESIDENCY", "1", 0)
        _ = backendInit
        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = Int32(config.gpuLayers)
        guard let model = llama_model_load_from_file(modelPath, mparams) else {
            throw LlamaCppError.modelLoadFailed(modelPath)
        }
        var cparams = llama_context_default_params()
        cparams.n_ctx = UInt32(max(0, config.contextTokens))
        guard let ctx = llama_init_from_model(model, cparams) else {
            llama_model_free(model)
            throw LlamaCppError.contextInitFailed
        }
        guard let vocab = llama_model_get_vocab(model) else {
            llama_free(ctx); llama_model_free(model)
            throw LlamaCppError.contextInitFailed
        }
        return LlamaContext(model: model, ctx: ctx, vocab: vocab, modelBytes: llama_model_size(model),
                            reusePromptPrefix: config.reusePromptPrefix)
    }

    /// Format the session using the model's built-in chat template when available; else a simple fallback.
    func formatPrompt(session: ChatSession) -> String {
        let normalized = PromptSessionNormalizer().normalized(session: session)
        let msgs = normalized.messages
        if let model, let tmpl = llama_model_chat_template(model, nil) {
            // Build C llama_chat_message array; keep Swift strings alive for the call.
            let roles: [UnsafeMutablePointer<CChar>] = msgs.map { strdup($0.role == .system ? "system" : ($0.role == .user ? "user" : "assistant"))! }
            let contents: [UnsafeMutablePointer<CChar>] = msgs.map { strdup($0.text)! }
            defer { roles.forEach { free($0) }; contents.forEach { free($0) } }
            var chat = [llama_chat_message]()
            for i in 0..<msgs.count {
                chat.append(llama_chat_message(role: UnsafePointer(roles[i]), content: UnsafePointer(contents[i])))
            }
            var buf = [CChar](repeating: 0, count: 8192)
            let n = llama_chat_apply_template(tmpl, &chat, chat.count, true, &buf, Int32(buf.count))
            if n > 0 {
                if Int(n) > buf.count {
                    buf = [CChar](repeating: 0, count: Int(n) + 1)
                    let n2 = llama_chat_apply_template(tmpl, &chat, chat.count, true, &buf, Int32(buf.count))
                    if n2 > 0 { return String(cString: buf) }
                } else {
                    return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
            }
        }
        // Fallback: plain role-tagged concatenation.
        return msgs.map { ($0.role == .user ? "User: " : $0.role == .assistant ? "Assistant: " : "") + $0.text }
            .joined(separator: "\n") + "\nAssistant:"
    }

    func generate(prompt: String, config: GenerationConfig,
                  onToken: @Sendable (String) -> Void,
                  isCancelled: @Sendable () -> Bool) throws -> Metrics {
        guard let ctx, let vocab else { throw LlamaCppError.unloaded }
        let promptTokens = try tokenize(prompt, vocab: vocab, addSpecial: true)
        guard !promptTokens.isEmpty else { throw LlamaCppError.tokenizeFailed }
        // Context-growth protection: the KV buffer is fixed at load (n_ctx), so a request cannot grow memory — but
        // it can overflow. Refuse a prompt that does not fit, and cap generation at the remaining room.
        let nCtx = Int(llama_n_ctx(ctx))
        guard promptTokens.count < nCtx else {
            throw LlamaCppError.contextOverflow(promptTokens: promptTokens.count, contextTokens: nCtx)
        }

        // Every request is independent: the full conversation is re-sent each turn, so nothing from the previous request
        // may influence this one. Without a reset a reused runtime (warm pool / managed SDK) decoded turn k on top of
        // turns 1…k-1 — wrong output from turn 2 and a "failed to find a memory slot" failure once n_ctx filled.
        // With prefix reuse, keep only the KV of the longest common token prefix with what is cached (always
        // re-decoding at least the last prompt token, for fresh logits) and remove everything after it.
        let memory = llama_get_memory(ctx)
        var reused = 0
        if reusePromptPrefix, !kvTokens.isEmpty {
            var lcp = 0
            let limit = min(kvTokens.count, promptTokens.count - 1)
            while lcp < limit, kvTokens[lcp] == promptTokens[lcp] { lcp += 1 }
            if lcp > 0, llama_memory_seq_rm(memory, 0, llama_pos(lcp), -1) { reused = lcp }
        }
        if reused == 0 { llama_memory_clear(memory, true) }
        kvTokens = Array(promptTokens.prefix(reused))

        let smpl = makeSampler(config: config)
        defer { llama_sampler_free(smpl) }

        let start = ContinuousClock.now
        var ttft: Duration?
        var generated = 0
        var finish = "stop"

        // Decode the prompt in n_batch chunks so a long prefill can be cancelled between chunks (and never exceeds
        // the batch limit llama_decode enforces).
        let nBatch = max(1, Int(llama_n_batch(ctx)))
        var offset = reused
        var promptBuffer = promptTokens
        while offset < promptBuffer.count {
            if isCancelled() { finish = "cancelled"; break }
            let n = min(nBatch, promptBuffer.count - offset)
            let rc: Int32 = promptBuffer.withUnsafeMutableBufferPointer { bp in
                llama_decode(ctx, llama_batch_get_one(bp.baseAddress! + offset, Int32(n)))
            }
            if rc != 0 { kvTokens = []; llama_memory_clear(memory, true); throw LlamaCppError.decodeFailed(rc) }
            kvTokens += promptBuffer[offset..<(offset + n)]
            offset += n
        }
        let prefillDone = ContinuousClock.now
        var firstToken: ContinuousClock.Instant?

        let maxTokens = finish == "cancelled" ? 0 : max(1, min(config.maxTokens, nCtx - promptTokens.count))
        while generated < maxTokens {
            if isCancelled() { finish = "cancelled"; break }
            let token = llama_sampler_sample(smpl, ctx, -1)
            if llama_vocab_is_eog(vocab, token) { finish = "stop"; break }
            if ttft == nil { ttft = start.duration(to: .now); firstToken = .now }
            onToken(piece(for: token, vocab: vocab))
            generated += 1
            if generated >= maxTokens { finish = "length"; break }
            var one = [token]
            let rc: Int32 = one.withUnsafeMutableBufferPointer { bp in
                let batch = llama_batch_get_one(bp.baseAddress, 1)
                return llama_decode(ctx, batch)
            }
            if rc != 0 { kvTokens = []; llama_memory_clear(memory, true); throw LlamaCppError.decodeFailed(rc) }
            kvTokens.append(token)
        }

        func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
        // Decode rate = tokens after the first / time after the first (the first token's logits come from prefill),
        // like llama.cpp's own eval timing. It used to divide by the whole call, under-reporting decode several-fold on
        // long prompts. Prefill rate counts only the tokens actually decoded (not the reused prefix).
        let decodeSecs = firstToken.map { seconds($0.duration(to: .now)) } ?? 0
        let prefillSecs = seconds(start.duration(to: prefillDone))
        var m = Metrics()
        m.ttftMilliseconds = ttft.map { seconds($0) * 1000 }
        m.generationTokens = generated
        m.promptTokens = promptTokens.count
        m.tokensPerSecond = decodeSecs > 0 && generated > 1 ? Double(generated - 1) / decodeSecs : nil
        m.promptTokensPerSecond = prefillSecs > 0 && finish != "cancelled" ? Double(promptTokens.count - reused) / prefillSecs : nil
        m.cachedTokens = reused
        m.cacheHit = reused > 0
        m.memoryBytes = Int64(modelBytes)
        m.finishReason = finish
        return m
    }

    func unload() {
        handles.free()
        vocab = nil
        kvTokens = []
    }

    // MARK: helpers

    private func makeSampler(config: GenerationConfig) -> UnsafeMutablePointer<llama_sampler> {
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())
        if config.temperature <= 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        } else {
            if let topP = config.topP { llama_sampler_chain_add(chain, llama_sampler_init_top_p(Float(topP), 1)) }
            llama_sampler_chain_add(chain, llama_sampler_init_temp(Float(config.temperature)))
            llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32(truncatingIfNeeded: config.seed ?? 0xDEADBEEF)))
        }
        return chain!
    }

    private func tokenize(_ text: String, vocab: OpaquePointer, addSpecial: Bool) throws -> [llama_token] {
        let utf8 = Array(text.utf8CString)
        let textLen = Int32(utf8.count - 1) // exclude null terminator
        var capacity = Int(textLen) + 16
        var tokens = [llama_token](repeating: 0, count: capacity)
        var n = tokens.withUnsafeMutableBufferPointer { tb in
            utf8.withUnsafeBufferPointer { cb in
                llama_tokenize(vocab, cb.baseAddress, textLen, tb.baseAddress, Int32(capacity), addSpecial, true)
            }
        }
        if n < 0 {
            capacity = Int(-n)
            tokens = [llama_token](repeating: 0, count: capacity)
            n = tokens.withUnsafeMutableBufferPointer { tb in
                utf8.withUnsafeBufferPointer { cb in
                    llama_tokenize(vocab, cb.baseAddress, textLen, tb.baseAddress, Int32(capacity), addSpecial, true)
                }
            }
        }
        guard n >= 0 else { throw LlamaCppError.tokenizeFailed }
        return Array(tokens.prefix(Int(n)))
    }

    private func piece(for token: llama_token, vocab: OpaquePointer) -> String {
        var buf = [CChar](repeating: 0, count: 128)
        var n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        }
        guard n > 0 else { return "" }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

extension LlamaCppEmbeddedBackend: BackendLifecycleDescribing {
    /// In-process llama.cpp: weights + a fixed `n_ctx` KV buffer stay resident in the loaded runtime until
    /// `unload()` (or the runtime is released). Each request starts from an isolated KV: fully cleared, or — with
    /// `reusePromptPrefix` — trimmed to the common token prefix with the previous request. One request at a time per
    /// loaded model (actor-serialized). Runs on iOS and macOS.
    public var lifecycleTraits: BackendLifecycleTraits {
        BackendLifecycleTraits(residency: .weightsResident, inProcess: true,
                               prefixReuse: config.reusePromptPrefix ? .residentTokens : .none,
                               serializesRequestsPerModel: true, contextBoundedAtLoad: true,
                               cancelsDuringPrefill: true, supportsIOS: true)
    }
}
