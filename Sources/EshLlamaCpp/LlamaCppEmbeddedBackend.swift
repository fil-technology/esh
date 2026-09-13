import Foundation
import EshCore
import llama

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
    public init(contextTokens: Int = 2048, gpuLayers: Int = 999) {
        self.contextTokens = contextTokens
        self.gpuLayers = gpuLayers
    }
}

public enum LlamaCppError: Error, LocalizedError, Sendable {
    case modelFileMissing(String)
    case modelLoadFailed(String)
    case contextInitFailed
    case tokenizeFailed
    case decodeFailed(Int32)
    public var errorDescription: String? {
        switch self {
        case let .modelFileMissing(p): return "GGUF model file not found at \(p)"
        case let .modelLoadFailed(p): return "llama.cpp failed to load the GGUF model at \(p)"
        case .contextInitFailed: return "llama.cpp failed to create a context"
        case .tokenizeFailed: return "llama.cpp failed to tokenize the prompt"
        case let .decodeFailed(code): return "llama.cpp decode failed (code \(code))"
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

    /// `resolveModelPath` maps an install to a local GGUF file path; defaults to `install.installPath`.
    public init(config: LlamaCppConfig = .init(),
                resolveModelPath: @escaping @Sendable (ModelInstall) -> String? = { $0.installPath.isEmpty ? nil : $0.installPath }) {
        self.config = config
        self.resolveModelPath = resolveModelPath
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

actor LlamaContext {
    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    private let modelBytes: UInt64

    private init(model: OpaquePointer, ctx: OpaquePointer, vocab: OpaquePointer, modelBytes: UInt64) {
        self.model = model
        self.ctx = ctx
        self.vocab = vocab
        self.modelBytes = modelBytes
    }

    static func make(modelPath: String, config: LlamaCppConfig) async throws -> LlamaContext {
        llama_backend_init()
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
        return LlamaContext(model: model, ctx: ctx, vocab: vocab, modelBytes: llama_model_size(model))
    }

    /// Format the session using the model's built-in chat template when available; else a simple fallback.
    func formatPrompt(session: ChatSession) -> String {
        let normalized = PromptSessionNormalizer().normalized(session: session)
        let msgs = normalized.messages
        if let tmpl = llama_model_chat_template(model, nil) {
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
        guard let ctx, let vocab else { throw LlamaCppError.contextInitFailed }
        let smpl = makeSampler(config: config)
        defer { llama_sampler_free(smpl) }

        var promptTokens = try tokenize(prompt, vocab: vocab, addSpecial: true)
        guard !promptTokens.isEmpty else { throw LlamaCppError.tokenizeFailed }

        let start = ContinuousClock.now
        var ttft: Duration?
        var generated = 0
        var finish = "stop"

        // Decode the prompt.
        try promptTokens.withUnsafeMutableBufferPointer { bp in
            let batch = llama_batch_get_one(bp.baseAddress, Int32(bp.count))
            if llama_decode(ctx, batch) != 0 { throw LlamaCppError.decodeFailed(1) }
        }

        let maxTokens = max(1, config.maxTokens)
        while generated < maxTokens {
            if isCancelled() { finish = "cancelled"; break }
            let token = llama_sampler_sample(smpl, ctx, -1)
            if llama_vocab_is_eog(vocab, token) { finish = "stop"; break }
            if ttft == nil { ttft = start.duration(to: .now) }
            onToken(piece(for: token, vocab: vocab))
            generated += 1
            if generated >= maxTokens { finish = "length"; break }
            var one = [token]
            let rc: Int32 = one.withUnsafeMutableBufferPointer { bp in
                let batch = llama_batch_get_one(bp.baseAddress, 1)
                return llama_decode(ctx, batch)
            }
            if rc != 0 { finish = "error"; throw LlamaCppError.decodeFailed(rc) }
        }

        let elapsed = start.duration(to: .now)
        let secs = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        var m = Metrics()
        m.ttftMilliseconds = ttft.map { Double($0.components.seconds) * 1000 + Double($0.components.attoseconds) / 1e15 }
        m.generationTokens = generated
        m.tokensPerSecond = secs > 0 ? Double(generated) / secs : nil
        m.memoryBytes = Int64(modelBytes)
        m.finishReason = finish
        return m
    }

    func unload() {
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
        ctx = nil; model = nil; vocab = nil
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
