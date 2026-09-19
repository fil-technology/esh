import Foundation

// esh 2.1 UCMR, Stage 0e — the execution entry point. Resolves an ExecutionRequest to a provider via
// the CapabilityRegistry and runs it, collecting typed CapabilityEvents into an ExecutionResult.
// language.generate is a real provider that bridges to the existing text inference path, so /v1/execute
// works end-to-end for text without touching the 2.0 chat path. See docs/UCMR_ARCHITECTURE.md §4,§12.

public enum CapabilityError: Error, LocalizedError, Equatable {
    case unsupported(capability: String, detail: String)
    case failed(String)
    /// The capability is supported but cannot safely run right now (memory / disk / swap headroom / offline).
    /// Transient: freeing resources or connecting the assets volume restores it. For an explicit model pin
    /// this is returned instead of substituting a different provider.
    case resourceGated(CapabilityResourceGate)

    public var errorDescription: String? {
        switch self {
        case let .unsupported(capability, detail): return "No local provider for \(capability): \(detail)"
        case let .failed(m): return m
        case let .resourceGated(gate): return gate.message
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
        // The inference stream appends an out-of-band execution-telemetry frame ("\u{01}ESHEXEC:{…}");
        // it is not user text, so strip it here (the SSE chat path emits it as a separate frame).
        let sentinel = "\u{01}ESHEXEC:"
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    for try await chunk in stream(extReq) {
                        if let range = chunk.range(of: sentinel) {
                            let prefix = String(chunk[chunk.startIndex..<range.lowerBound])
                            if !prefix.isEmpty { cont.yield(.textDelta(prefix)) }
                        } else {
                            cont.yield(.textDelta(chunk))
                        }
                    }
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
    /// Optional capability-aware model resolver: fills `model` when a request omits it (Auto across
    /// modalities). Returns nil to leave the model unresolved (e.g. capabilities that need no model).
    private let modelResolver: (@Sendable (ExecutionRequest) -> String?)?
    /// Stage 4.2c: performance-aware Auto. Optional; when present, consulted before the plain model
    /// resolver to pick an evidence-backed model and (for interactive requests) config.
    private let scheduler: CapabilityScheduler?
    private let candidateModels: (@Sendable (CapabilityID) -> [String])?
    /// Resource-aware Auto routing. When present, providers that declare a `CapabilityResourceProfile` are
    /// ranked by quality and filtered to those that safely fit the live machine (memory + per-volume disk +
    /// swap headroom + generic policy). `resourceHost` reads the live machine once per request; `providerState`
    /// reports install/warm state per provider. When nil, selection is the legacy native-first `.first`.
    private let resourceHost: (@Sendable () -> HostResources)?
    private let providerState: (@Sendable (String) -> ProviderRuntimeState)?
    private let resourceScheduler: ResourceScheduler

    public init(registry: CapabilityRegistry, context: ExecutionContext,
                modelResolver: (@Sendable (ExecutionRequest) -> String?)? = nil,
                scheduler: CapabilityScheduler? = nil,
                candidateModels: (@Sendable (CapabilityID) -> [String])? = nil,
                resourceHost: (@Sendable () -> HostResources)? = nil,
                providerState: (@Sendable (String) -> ProviderRuntimeState)? = nil) {
        self.registry = registry
        self.context = context
        self.modelResolver = modelResolver
        self.scheduler = scheduler
        self.candidateModels = candidateModels
        self.resourceHost = resourceHost
        self.providerState = providerState
        self.resourceScheduler = ResourceScheduler()
    }

    /// Apply performance-aware scheduling (evidence-backed model + interactive config) to a request.
    /// Returns the possibly-modified request and the decision (for plan annotation). Pure w.r.t. providers.
    private func scheduled(_ request: ExecutionRequest) -> (ExecutionRequest, CapabilityScheduleDecision) {
        guard let scheduler else { return (request, .none) }
        var req = request
        let costKeys = ["width", "height", "steps", "scale"]
        let cfg = costKeys.reduce(into: [String: JSONValue]()) { acc, k in if let v = req.options.values[k] { acc[k] = v } }
        let candidates = candidateModels?(req.capability) ?? []
        let decision = scheduler.decide(capability: req.capability, currentModel: req.model,
                                        candidateModelIDs: candidates, requestedConfig: cfg,
                                        latency: req.constraints.latency)
        if req.model == nil, let m = decision.modelID { req.model = m }
        for (k, v) in decision.optionOverrides where req.options.values[k] == nil { req.options.values[k] = v }
        return (req, decision)
    }

    public func execute(_ request: ExecutionRequest) -> AsyncThrowingStream<CapabilityEvent, Error> {
        let (scheduledRequest, _) = scheduled(request)
        return runResolved(scheduledRequest)
    }

    /// Run a request that has already been through `scheduled(_:)` (model resolver fallback + dispatch).
    private func runResolved(_ request: ExecutionRequest) -> AsyncThrowingStream<CapabilityEvent, Error> {
        var request = request
        if request.model == nil, let resolved = modelResolver?(request) { request.model = resolved }
        let candidates = registry.candidates(for: request)
        guard !candidates.isEmpty else {
            let mods = request.inputs.map { $0.modality.rawValue }.joined(separator: "+")
            let detail = "inputs=[\(mods)] output=\(request.output.modality.rawValue). Install or enable a provider for this capability."
            return AsyncThrowingStream { cont in
                cont.finish(throwing: CapabilityError.unsupported(capability: request.capability.rawValue, detail: detail))
            }
        }

        // Resource-aware selection (Auto ranks by quality among safely-fitting tiers; an explicit pin is
        // honored-or-gated, never substituted). Falls through to legacy `.first` when no provider declares a
        // resource profile, or when resource detection is not wired.
        var chosen = candidates[0]
        var selectionReason: String?
        if let resourceHost {
            let host = resourceHost()
            let rc = candidates.map { p -> ResourceCandidate in
                ResourceCandidate(providerID: p.descriptor.id, profile: p.descriptor.resourceProfile,
                                  state: providerState?(p.descriptor.id) ?? .init())
            }
            let outcome = resourceScheduler.select(
                capability: request.capability.rawValue, explicit: request.model != nil,
                candidates: rc, host: host, policy: request.constraints.resourcePolicy)
            switch outcome {
            case let .passthrough(reason):
                selectionReason = reason
            case let .selected(providerID, diag):
                chosen = candidates.first { $0.descriptor.id == providerID } ?? candidates[0]
                selectionReason = diag.reason
            case let .gated(gate, _):
                return AsyncThrowingStream { cont in
                    cont.yield(.failed(message: gate.message))
                    cont.finish(throwing: CapabilityError.resourceGated(gate))
                }
            }
        }

        let provider = chosen
        let resolved = ResolvedExecutionRequest(request: request, modelID: request.model)
        let downstream = provider.execute(resolved, context: context)
        guard let selectionReason else { return downstream }
        // Prepend the routing rationale as a status line (explainable routing) without altering the payload.
        return AsyncThrowingStream { cont in
            let task = Task {
                cont.yield(.status(selectionReason))
                do {
                    for try await ev in downstream { cont.yield(ev) }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// Run to completion, collecting a typed ExecutionResult (text and/or artifacts).
    public func executeCollecting(_ request: ExecutionRequest) async throws -> ExecutionResult {
        let (scheduledRequest, decision) = scheduled(request)
        var text = ""
        var outputs: [Artifact] = []
        var usage: EshUsage?
        var plan: ExecutionPlan?
        var previewURL: String?
        for try await event in runResolved(scheduledRequest) {
            switch event {
            case .textDelta(let s): text += s
            case .artifactProduced(let a): outputs.append(a)
            case .usage(let u): usage = u
            case .planResolved(let p): plan = p
            case .previewReady(let url): previewURL = url
            case .failed(let m): throw CapabilityError.failed(m)
            case .status, .progress, .reasoningDelta, .done: break
            }
        }
        // Fold the performance-aware decision into the plan ("Why this execution plan?").
        if !decision.rationale.isEmpty || decision.evidenceBacked {
            if var p = plan {
                p.rationale.append(contentsOf: decision.rationale)
                p.evidenceBacked = p.evidenceBacked || decision.evidenceBacked
                plan = p
            } else if !decision.rationale.isEmpty {
                plan = ExecutionPlan(capability: request.capability,
                                     inputModalities: request.inputs.map { $0.modality },
                                     outputModality: request.output.modality,
                                     steps: [], rationale: decision.rationale, evidenceBacked: decision.evidenceBacked)
            }
        }
        return ExecutionResult(
            capability: request.capability,
            text: text.isEmpty ? nil : text,
            outputs: outputs,
            usage: usage,
            plan: plan,
            previewURL: previewURL)
    }
}
