import Foundation

// esh 2.1 UCMR, Stage 0e — the execution entry point. Resolves an ExecutionRequest to a provider via
// the CapabilityRegistry and runs it, collecting typed CapabilityEvents into an ExecutionResult.
// language.generate is a real provider that bridges to the existing text inference path, so /v1/execute
// works end-to-end for text without touching the 2.0 chat path. See docs/UCMR_ARCHITECTURE.md §4,§12.

public enum CapabilityError: Error, LocalizedError, Equatable {
    case unsupported(capability: String, detail: String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupported(capability, detail): return "No local provider for \(capability): \(detail)"
        case let .failed(m): return m
        }
    }
}

/// Adapts between the additive ExecutionRequest and the retained Inference Contract v2 text types, so
/// 2.0 callers and the text path are untouched.
public enum CapabilityAdapters {
    public static func role(from raw: String?) -> Message.Role {
        switch raw?.lowercased() {
        case "system": return .system
        case "assistant": return .assistant
        case "tool": return .tool
        default: return .user
        }
    }

    private static func stringify(_ v: JSONValue) -> String {
        (try? String(decoding: JSONEncoder().encode(v), as: UTF8.self)) ?? ""
    }

    private static func responseFormat(from output: OutputSpec) -> EshResponseFormat? {
        switch output.modality {
        case .json:
            if let schema = output.schema { return EshResponseFormat(kind: .jsonSchema, schema: schema, strict: true) }
            return .json
        case .text:
            return nil
        default:
            return nil
        }
    }

    /// ExecutionRequest → ExternalInferenceRequest for language capabilities.
    public static func inferenceRequest(from req: ExecutionRequest) -> ExternalInferenceRequest {
        var messages: [ExternalInferenceMessage] = []
        var attachments: [EshAttachment] = []
        for input in req.inputs {
            switch input.payload {
            case .text(let t): messages.append(ExternalInferenceMessage(role: role(from: input.role), text: t))
            case .structured(let v): messages.append(ExternalInferenceMessage(role: .user, text: stringify(v)))
            case .attachment(let a): attachments.append(a)
            case .embedding: break
            }
        }
        var gen = GenerationConfig()
        if case .int(let mt)? = req.options.values["maxTokens"] { gen.maxTokens = mt }
        if case .double(let t)? = req.options.values["temperature"] { gen.temperature = t }
        if case .int(let t)? = req.options.values["temperature"] { gen.temperature = Double(t) }
        return ExternalInferenceRequest(
            model: req.model,
            messages: messages,
            generation: gen,
            responseFormat: responseFormat(from: req.output),
            attachments: attachments.isEmpty ? nil : attachments)
    }

    /// ExternalInferenceRequest → ExecutionRequest (language.generate) for the compatibility adapter.
    public static func executionRequest(from req: ExternalInferenceRequest) -> ExecutionRequest {
        var inputs: [CapabilityInput] = req.messages.map { .text($0.text, role: $0.role.rawValue) }
        for a in req.attachments ?? [] { inputs.append(.attachment(a)) }
        let output: OutputSpec
        switch req.responseFormat?.kind {
        case .json, .jsonSchema: output = OutputSpec(modality: .json, schema: req.responseFormat?.schema)
        default: output = .text
        }
        var options: [String: JSONValue] = ["maxTokens": .int(req.generation.maxTokens),
                                            "temperature": .double(req.generation.temperature)]
        if options.isEmpty { options = [:] }
        return ExecutionRequest(capability: .languageGenerate, inputs: inputs, output: output,
                                options: ExecutionOptions(options), model: req.model)
    }
}

/// A real CapabilityProvider for text generation that bridges to the existing inference stream. This
/// makes language.* a first-class provider (not a special case) while reusing all of the 2.0 text path.
public struct LanguageGenerateProvider: CapabilityProvider {
    public typealias StreamFn = @Sendable (ExternalInferenceRequest) -> AsyncThrowingStream<String, Error>

    public let descriptor: CapabilityProviderDescriptor
    private let streamFn: StreamFn

    public init(id: String = "language-generate",
                capabilities: [CapabilityID] = [.languageGenerate, .languageReason, .languageSummarize,
                                                .languageTranslate, .languageClassify, .languageExtract],
                stream: @escaping StreamFn) {
        self.descriptor = CapabilityProviderDescriptor(
            id: id,
            capabilities: capabilities,
            acceptedInputs: [.text],
            producedOutputs: [.text, .json],
            backend: .mlx,           // format-agnostic here; the underlying registry picks the real backend
            streaming: true,
            structuredOutput: true,
            requiredPrivilege: .artifactOnly,
            previewMode: .none)
        self.streamFn = stream
    }

    public func execute(_ request: ResolvedExecutionRequest,
                        context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        let extReq = CapabilityAdapters.inferenceRequest(from: request.request)
        let stream = streamFn
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    for try await chunk in stream(extReq) { cont.yield(.textDelta(chunk)) }
                    cont.yield(.done(finishReason: "stop"))
                    cont.finish()
                } catch {
                    cont.yield(.failed(message: error.localizedDescription))
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}

/// Resolves + runs capability requests. Stage 0: picks the first compatible provider (scheduler
/// capability-resolution is Stage 2). Providers persist their own artifacts to the context store.
public struct CapabilityExecutionService: Sendable {
    private let registry: CapabilityRegistry
    private let context: ExecutionContext

    public init(registry: CapabilityRegistry, context: ExecutionContext) {
        self.registry = registry
        self.context = context
    }

    public func execute(_ request: ExecutionRequest) -> AsyncThrowingStream<CapabilityEvent, Error> {
        let candidates = registry.candidates(for: request)
        guard let provider = candidates.first else {
            let mods = request.inputs.map { $0.modality.rawValue }.joined(separator: "+")
            let detail = "inputs=[\(mods)] output=\(request.output.modality.rawValue). Install or enable a provider for this capability."
            return AsyncThrowingStream { cont in
                cont.finish(throwing: CapabilityError.unsupported(capability: request.capability.rawValue, detail: detail))
            }
        }
        let resolved = ResolvedExecutionRequest(request: request, modelID: request.model)
        return provider.execute(resolved, context: context)
    }

    /// Run to completion, collecting a typed ExecutionResult (text and/or artifacts).
    public func executeCollecting(_ request: ExecutionRequest) async throws -> ExecutionResult {
        var text = ""
        var outputs: [Artifact] = []
        var usage: EshUsage?
        for try await event in execute(request) {
            switch event {
            case .textDelta(let s): text += s
            case .artifactProduced(let a): outputs.append(a)
            case .usage(let u): usage = u
            case .failed(let m): throw CapabilityError.failed(m)
            case .status, .progress, .reasoningDelta, .previewReady, .done: break
            }
        }
        return ExecutionResult(
            capability: request.capability,
            text: text.isEmpty ? nil : text,
            outputs: outputs,
            usage: usage)
    }
}
