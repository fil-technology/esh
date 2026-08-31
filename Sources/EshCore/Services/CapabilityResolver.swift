import Foundation

/// Resolves requested inference options against what the target backend can actually do, producing
/// an honest `CapabilityResolution` (applied/transformed/approximated/ignored/rejected) plus, where a
/// constraint can be enforced natively, the concrete native constraint the backend should apply.
/// Implements the M8 principle: never silently pretend an unsupported option was honored, and never
/// silently treat a prompt instruction as equivalent to constrained decoding.
public struct CapabilityResolver: Sendable {
    public init() {}

    public struct Outcome: Sendable {
        public var resolution: CapabilityResolution
        /// A system instruction to inject to APPROXIMATE the request (e.g. JSON via prompt), or nil.
        /// Only set for non-native (approximated) handling.
        public var systemInstructionAugmentation: String?
        /// A JSON schema to enforce NATIVELY via constrained decoding (backend fills this into the
        /// generation config). Set only when the backend genuinely supports it.
        public var nativeJSONSchema: String?
        /// A GBNF grammar to enforce NATIVELY via constrained decoding. Set only when supported.
        public var nativeGrammar: String?

        init(
            resolution: CapabilityResolution,
            systemInstructionAugmentation: String? = nil,
            nativeJSONSchema: String? = nil,
            nativeGrammar: String? = nil
        ) {
            self.resolution = resolution
            self.systemInstructionAugmentation = systemInstructionAugmentation
            self.nativeJSONSchema = nativeJSONSchema
            self.nativeGrammar = nativeGrammar
        }
    }

    /// Whether a backend can enforce structured output via native constrained decoding.
    /// GGUF (llama.cpp) supports GBNF grammars and JSON-schema-to-grammar natively; MLX and ONNX do
    /// not have it wired, so they honestly approximate/reject instead.
    static func supportsNativeConstrainedDecoding(_ backend: BackendKind) -> Bool {
        backend == .gguf
    }

    public func resolve(
        responseFormat: EshResponseFormat?,
        backend: BackendKind,
        tools: [EshToolDefinition]? = nil,
        reasoningEnabled: Bool? = nil
    ) -> Outcome {
        var extraOptions: [ResolvedOption] = []
        // Tools: native model function-calling is not wired into the local runtime yet, so requested
        // tools are honestly reported as rejected (the esh agent layer does tool orchestration
        // separately). This is not silent — the caller sees it in capabilityResolution.
        if let tools, !tools.isEmpty {
            extraOptions.append(ResolvedOption(name: "tools", resolution: .rejected,
                detail: "native tool/function calling is not available on the \(backend.rawValue) runtime yet; use `esh agent` for tool orchestration"))
        }

        // Reasoning/thinking: only report when the caller explicitly asked to toggle it. Grounded in
        // real backend behavior — never claim a reasoning channel that isn't honored.
        if let reasoningEnabled {
            extraOptions.append(resolveReasoning(enabled: reasoningEnabled, backend: backend))
        }

        guard let responseFormat else {
            return Outcome(resolution: CapabilityResolution(options: extraOptions))
        }

        let base = resolveFormat(responseFormat, backend: backend)
        return Outcome(
            resolution: CapabilityResolution(options: base.resolution.options + extraOptions),
            systemInstructionAugmentation: base.systemInstructionAugmentation,
            nativeJSONSchema: base.nativeJSONSchema,
            nativeGrammar: base.nativeGrammar
        )
    }

    /// Honest per-backend reasoning handling. MLX passes `enable_thinking` into the model's chat
    /// template (a real control); llama.cpp/ONNX have no such toggle — the GGUF chat template decides
    /// and any thinking tokens are emitted inline, not separately accounted. We never fabricate a
    /// reasoning-token count for backends that don't report one (see EshUsage.reasoningTokens).
    private func resolveReasoning(enabled: Bool, backend: BackendKind) -> ResolvedOption {
        switch backend {
        case .mlx:
            return ResolvedOption(name: "reasoning", resolution: .applied,
                detail: enabled
                    ? "enable_thinking passed to the model chat template; reasoning tokens are not separately reported"
                    : "thinking disabled via the model chat template")
        case .gguf, .onnx:
            return ResolvedOption(name: "reasoning", resolution: .ignored,
                detail: "the \(backend.rawValue) runtime has no reasoning toggle; the model/template decides and any thinking is emitted inline (not separately accounted)")
        }
    }

    private func resolveFormat(_ responseFormat: EshResponseFormat, backend: BackendKind) -> Outcome {
        let native = Self.supportsNativeConstrainedDecoding(backend)
        switch responseFormat.kind {
        case .text:
            return Outcome(resolution: CapabilityResolution(options: [
                ResolvedOption(name: "response_format", resolution: .applied, detail: "text")
            ]))

        case .json:
            if native {
                // Enforce "any JSON object" natively via a permissive JSON schema.
                return Outcome(
                    resolution: CapabilityResolution(options: [
                        ResolvedOption(name: "response_format", resolution: .applied,
                            detail: "json enforced natively via constrained decoding on \(backend.rawValue)")
                    ]),
                    nativeJSONSchema: #"{"type":"object"}"#
                )
            }
            // No native constrained JSON decoding on this backend. Strict callers get a rejection
            // rather than a prompt-instruction approximation.
            if responseFormat.strict {
                return Outcome(resolution: CapabilityResolution(options: [
                    ResolvedOption(name: "response_format", resolution: .rejected,
                        detail: "strict json requested but the \(backend.rawValue) runtime has no native constrained decoding; not approximating because strict was set")
                ]))
            }
            return Outcome(
                resolution: CapabilityResolution(options: [
                    ResolvedOption(name: "response_format", resolution: .approximated,
                        detail: "json approximated via a prompt instruction (no native constrained decoding on \(backend.rawValue)); validity is not guaranteed. Set strict to reject approximation.")
                ]),
                systemInstructionAugmentation: "Respond with a single valid JSON object and nothing else. Do not include markdown code fences or any prose."
            )

        case .jsonSchema:
            let schema = responseFormat.schema?.trimmingCharacters(in: .whitespacesAndNewlines)
            if native {
                // llama.cpp converts a JSON schema to a grammar and enforces it during decoding.
                let effectiveSchema = (schema?.isEmpty == false) ? schema! : #"{"type":"object"}"#
                return Outcome(
                    resolution: CapabilityResolution(options: [
                        ResolvedOption(name: "response_format", resolution: .applied,
                            detail: "json_schema enforced natively via constrained decoding on \(backend.rawValue)")
                    ]),
                    nativeJSONSchema: effectiveSchema
                )
            }
            if responseFormat.strict {
                return Outcome(resolution: CapabilityResolution(options: [
                    ResolvedOption(name: "response_format", resolution: .rejected,
                        detail: "strict json_schema requested but no native constrained decoding is available on \(backend.rawValue); not approximating because strict was set")
                ]))
            }
            let augmentation = "Respond with a single JSON object that strictly conforms to this JSON Schema, and nothing else:\n\(schema ?? "(the requested schema)")"
            return Outcome(
                resolution: CapabilityResolution(options: [
                    ResolvedOption(name: "response_format", resolution: .approximated,
                        detail: "json_schema approximated via a prompt instruction (no native constrained decoding on \(backend.rawValue)); conformance is not guaranteed. Set strict to reject approximation.")
                ]),
                systemInstructionAugmentation: augmentation
            )

        case .grammar:
            let grammar = responseFormat.grammar?.trimmingCharacters(in: .whitespacesAndNewlines)
            if native, let grammar, !grammar.isEmpty {
                return Outcome(
                    resolution: CapabilityResolution(options: [
                        ResolvedOption(name: "response_format", resolution: .applied,
                            detail: "grammar enforced natively via constrained decoding (GBNF) on \(backend.rawValue)")
                    ]),
                    nativeGrammar: grammar
                )
            }
            if native {
                return Outcome(resolution: CapabilityResolution(options: [
                    ResolvedOption(name: "response_format", resolution: .rejected,
                        detail: "grammar constrained decoding requested but no grammar text was provided")
                ]))
            }
            return Outcome(resolution: CapabilityResolution(options: [
                ResolvedOption(name: "response_format", resolution: .rejected,
                    detail: "grammar-constrained decoding is not available in the current \(backend.rawValue) runtime")
            ]))
        }
    }
}
