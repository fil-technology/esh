import Foundation

/// A `BackendRuntime` backed by a persistent `llama-server` (see `LlamaServerProcess`). The model is
/// loaded ONCE when the runtime is created and stays resident until `unload()`. Generation maps the
/// canonical esh conversation to an OpenAI chat-completions request and streams it to the already-
/// loaded server, which applies the model's native chat template and stops at its native end-of-turn.
///
/// `RuntimeLifecycleManager` owns instances of this type (eviction/idle/pressure), same as the MLX
/// persistent runtime.
public final class LlamaServerRuntime: BackendRuntime, ResidencyReporting, @unchecked Sendable {
    public let backend: BackendKind = .gguf
    public let modelID: String

    private let server: LlamaServerProcess
    private let install: ModelInstall
    private let lock = NSLock()
    private var currentMetrics: Metrics

    init(server: LlamaServerProcess, install: ModelInstall) {
        self.server = server
        self.install = install
        self.modelID = install.id
        self.currentMetrics = Metrics()
    }

    public var residency: RuntimeResidency { server.isAlive ? .weightsResident : .handleCached }
    public var loadLatencyMilliseconds: Double { server.loadMilliseconds }
    public var isHealthy: Bool { server.isAlive }

    public var metrics: Metrics { lock.lock(); defer { lock.unlock() }; return currentMetrics }
    private func setMetrics(_ m: Metrics) { lock.lock(); currentMetrics = m; lock.unlock() }

    public func prepare(session: ChatSession) async throws {}

    public func generate(
        session: ChatSession,
        config: GenerationConfig
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let body: Data
            do {
                body = try Self.requestBody(session: session, config: config)
            } catch {
                continuation.finish(throwing: error)
                return
            }
            let start = ContinuousClock.now
            let events = server.generate(body: body)
            let task = Task {
                var sawFirst = false
                do {
                    for try await delta in events {
                        if !sawFirst {
                            sawFirst = true
                            let elapsed = start.duration(to: .now)
                            let ms = Double(elapsed.components.seconds) * 1_000
                                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
                            self.setMetrics(Metrics(ttftMilliseconds: ms))
                        }
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { reason in
                if case .cancelled = reason { task.cancel() }
            }
        }
    }

    /// Build the OpenAI chat-completions request. The conversation is passed as `messages` so
    /// `llama-server --jinja` applies the model's own template; we never format role delimiters here.
    static func requestBody(session: ChatSession, config: GenerationConfig) throws -> Data {
        let normalized = PromptSessionNormalizer().normalized(session: session)
        let messages: [[String: String]] = normalized.messages.map { ["role": $0.role.rawValue, "content": $0.text] }

        var body: [String: Any] = [
            "messages": messages,
            "stream": true,
            "max_tokens": config.maxTokens,
            "temperature": config.temperature,
            "cache_prompt": true
        ]
        if let topP = config.topP { body["top_p"] = topP }
        if let topK = config.topK { body["top_k"] = topK }
        if let minP = config.minP { body["min_p"] = minP }
        if let rp = config.repetitionPenalty { body["repeat_penalty"] = rp }
        if let seed = config.seed { body["seed"] = Int(bitPattern: UInt(seed)) }
        if let stop = config.stop, !stop.isEmpty { body["stop"] = stop }

        // Native constrained decoding (M8): a JSON schema (via response_format) takes precedence over a
        // raw GBNF grammar. llama-server converts the schema to a grammar internally.
        if let schema = config.jsonSchema, !schema.isEmpty,
           let schemaObj = try? JSONSerialization.jsonObject(with: Data(schema.utf8)) {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": ["name": "response", "schema": schemaObj, "strict": true]
            ]
        } else if let grammar = config.grammar, !grammar.isEmpty {
            body["grammar"] = grammar
        }

        return try JSONSerialization.data(withJSONObject: body, options: [])
    }

    public func exportRuntimeCache() async throws -> CacheSnapshot {
        throw StoreError.invalidManifest("GGUF cache export is not supported by the llama.cpp backend yet.")
    }

    public func importRuntimeCache(_ snapshot: CacheSnapshot) async throws {
        throw StoreError.invalidManifest("GGUF cache import is not supported by the llama.cpp backend yet.")
    }

    public func validateCacheCompatibility(_ manifest: CacheManifest) async throws {
        throw CompatibilityIssue(reason: "GGUF cache compatibility is not supported by the llama.cpp backend yet.")
    }

    public func unload() async {
        server.shutdown()
    }
}
