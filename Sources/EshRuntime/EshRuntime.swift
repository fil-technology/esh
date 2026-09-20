import Foundation
import EshCore
#if canImport(Speech)
import Speech
#endif

// esh 2.x — M3: the app-facing runtime facade.
//
// `EshRuntime` is a thin, Swift 6-concurrency-safe facade over the EXISTING esh architecture. It reuses
// `InferenceBackendRegistry` (the same platform assembly the CLI uses), the existing `InferenceBackend` /
// `BackendRuntime` contracts, `ChatSession` / `Message` / `GenerationConfig`, and the existing capability
// reporting (`BackendCapabilityReport`, `AppleIntelligenceStatus`). It introduces NO parallel routing or
// model-selection architecture: selection is a thin, honest choice over the registry's candidates.
//
// A caller can run inference without constructing `AppleBackend` / `MLXBackend` / `LlamaCppBackend`, a
// registry, a scheduler, or a backend runtime. Lower-level APIs remain public in `EshCore` for advanced use.

// MARK: - Public request / result / capability types

/// Constraints a caller places on how a request may be served.
public struct EshConstraints: Sendable {
    /// Hard constraint: only backends that execute locally/on-device may serve the request. esh has no
    /// hidden cloud fallback, so this is always honored; a backend whose execution is not local is refused
    /// rather than silently used. Defaults to `true` (local-first).
    public var localOnly: Bool
    /// Explicit provider/model pin. When set, esh uses exactly this model and never silently substitutes a
    /// different provider (e.g. Apple Foundation Models) for it. Use `AppleProvider.canonicalModelID`
    /// (or any reserved Apple id) to pin Apple explicitly. `nil` means Auto selection.
    public var pinnedModelID: String?

    public init(localOnly: Bool = true, pinnedModelID: String? = nil) {
        self.localOnly = localOnly
        self.pinnedModelID = pinnedModelID
    }

    public static let auto = EshConstraints()
    public static let localOnly = EshConstraints(localOnly: true)
    public static func pinned(_ modelID: String, localOnly: Bool = true) -> EshConstraints {
        EshConstraints(localOnly: localOnly, pinnedModelID: modelID)
    }
}

/// A generation request. Build it from a plain prompt or from explicit `EshCore.Message`s.
public struct EshGenerationRequest: Sendable {
    public var messages: [Message]
    public var constraints: EshConstraints
    public var config: GenerationConfig
    /// Requested output format (text/json/json_schema/grammar). Resolved honestly against the selected
    /// backend: enforced natively via constrained decoding when supported, otherwise approximated by an
    /// injected system instruction, otherwise (strict) refused. Reflected in `EshGenerationResult.capabilityResolution`.
    public var responseFormat: EshResponseFormat?
    /// Tool/function definitions the model may call. NOTE: native local tool-calling is not available on
    /// esh's on-device runtimes today; these are accepted and reported (see `capabilityResolution`) but a
    /// `.toolCall` is only ever emitted when a backend genuinely produces one — never fabricated.
    public var tools: [EshToolDefinition]?
    public var toolChoice: EshToolChoice?

    public init(messages: [Message], constraints: EshConstraints = .auto, config: GenerationConfig = .init(),
                responseFormat: EshResponseFormat? = nil, tools: [EshToolDefinition]? = nil,
                toolChoice: EshToolChoice? = nil) {
        self.messages = messages
        self.constraints = constraints
        self.config = config
        self.responseFormat = responseFormat
        self.tools = tools
        self.toolChoice = toolChoice
    }

    /// Convenience: a single user prompt with an optional system instruction.
    public init(prompt: String, system: String? = nil, constraints: EshConstraints = .auto,
                config: GenerationConfig = .init(), responseFormat: EshResponseFormat? = nil,
                tools: [EshToolDefinition]? = nil, toolChoice: EshToolChoice? = nil) {
        var msgs: [Message] = []
        if let system, !system.isEmpty { msgs.append(Message(role: .system, text: system)) }
        msgs.append(Message(role: .user, text: prompt))
        self.init(messages: msgs, constraints: constraints, config: config,
                  responseFormat: responseFormat, tools: tools, toolChoice: toolChoice)
    }
}

/// Which backend/model esh actually selected, and why — the inspectable "why this backend?" metadata.
public struct EshSelection: Sendable, Equatable {
    public var backend: BackendKind
    public var modelID: String
    public var reason: String
    public var localOnlySatisfied: Bool
    public init(backend: BackendKind, modelID: String, reason: String, localOnlySatisfied: Bool) {
        self.backend = backend
        self.modelID = modelID
        self.reason = reason
        self.localOnlySatisfied = localOnlySatisfied
    }
}

/// The result of a one-shot generation.
public struct EshGenerationResult: Sendable {
    public var text: String
    public var selection: EshSelection
    public var metrics: Metrics
    /// The model's separated reasoning/thinking chain, when it emitted one and `config.enableThinking` was
    /// set (parsed out of the visible text). `nil` otherwise.
    public var reasoning: String?
    /// How the request's `responseFormat`/`tools` were resolved against the selected backend (native /
    /// approximated / rejected). `nil` when neither was requested.
    public var capabilityResolution: CapabilityResolution?
    public init(text: String, selection: EshSelection, metrics: Metrics,
                reasoning: String? = nil, capabilityResolution: CapabilityResolution? = nil) {
        self.text = text
        self.selection = selection
        self.metrics = metrics
        self.reasoning = reasoning
        self.capabilityResolution = capabilityResolution
    }
}

/// Streaming events. `token` carries incremental visible text; `reasoningDelta` carries incremental
/// reasoning/thinking text (only when the model separates it and `config.enableThinking` is set);
/// `toolCall` is emitted only when a backend genuinely produces one (never fabricated — see
/// `EshGenerationRequest.tools`); `completed` carries the final assembled result.
public enum EshGenerationEvent: Sendable {
    case token(String)
    case reasoningDelta(String)
    case toolCall(EshToolCall)
    case completed(EshGenerationResult)
}

/// Availability of one backend on this device.
public struct EshBackendAvailability: Sendable {
    public var backend: BackendKind
    public var report: BackendCapabilityReport
    public var isLocal: Bool
    public init(backend: BackendKind, report: BackendCapabilityReport, isLocal: Bool) {
        self.backend = backend
        self.report = report
        self.isLocal = isLocal
    }
}

/// A snapshot of what esh can do on this device right now.
public struct EshCapabilitySnapshot: Sendable {
    /// Backends wired by the platform assembly, with their live capability reports.
    public var backends: [EshBackendAvailability]
    /// The Apple Foundation Models status (also surfaced via `backends` when Apple is wired).
    public var appleIntelligence: AppleIntelligenceStatus
    public init(backends: [EshBackendAvailability], appleIntelligence: AppleIntelligenceStatus) {
        self.backends = backends
        self.appleIntelligence = appleIntelligence
    }
    /// True when at least one backend is ready to serve a request.
    public var hasReadyBackend: Bool { backends.contains { $0.report.ready } }
}

/// Typed errors from the facade. A production host can switch over these exhaustively and never has to
/// parse a human string to decide what to do; the associated `reason`/`errorDescription` is display text.
public enum EshRuntimeError: Error, Sendable, Equatable, LocalizedError {
    /// Auto selection found no backend that can serve the request on this device.
    case noAvailableBackend(reason: String)
    /// A pinned model was requested but is not installed / not ready. esh NEVER substitutes another
    /// provider for a pin, so this surfaces instead of a silent fallback.
    case pinnedModelUnavailable(modelID: String, reason: String)
    /// The backend a model needs is not wired on this platform (e.g. an MLX model on iOS).
    case backendUnavailable(BackendKind, reason: String)
    /// The `localOnly` constraint cannot be satisfied (no local backend can serve it).
    case localOnlyViolation(reason: String)
    /// This device/OS cannot run the selected backend at all (e.g. Apple Intelligence unsupported hardware,
    /// or OS below the Foundation Models floor). Distinct from a transient "not ready".
    case unsupportedDevice(reason: String)
    /// The selected backend's runtime failed to load the model (e.g. llama.cpp could not open the GGUF,
    /// or the weights are missing/corrupt). Carries the model id and an honest reason.
    case modelLoadFailed(modelID: String, reason: String)
    /// Generation started but failed mid-stream (backend error, decode failure, or resource exhaustion).
    case generationFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case let .noAvailableBackend(reason): return "No local intelligence backend is available: \(reason)"
        case let .pinnedModelUnavailable(id, reason): return "Pinned model '\(id)' is unavailable: \(reason)"
        case let .backendUnavailable(kind, reason): return "Backend '\(kind.rawValue)' is unavailable: \(reason)"
        case let .localOnlyViolation(reason): return "localOnly constraint cannot be satisfied: \(reason)"
        case let .unsupportedDevice(reason): return "This device cannot run the selected backend: \(reason)"
        case let .modelLoadFailed(id, reason): return "Failed to load model '\(id)': \(reason)"
        case let .generationFailed(reason): return "Generation failed: \(reason)"
        }
    }
}

// MARK: - Dependency injection seam

/// Supplies the installed downloadable models used for pinning / Auto (macOS has a model store; iOS has
/// none by default). Injecting this makes the facade fully testable without a filesystem.
public protocol EshInstallProviding: Sendable {
    func installs() -> [ModelInstall]
}

/// Default install provider backed by the on-disk model store. Returns `[]` on failure (honest empty).
public struct FileInstallProvider: EshInstallProviding {
    private let root: PersistenceRoot
    public init(root: PersistenceRoot = .default()) { self.root = root }
    public func installs() -> [ModelInstall] {
        (try? FileModelStore(root: root).listInstalls()) ?? []
    }
}

/// An install provider that returns a fixed list (used for tests / advanced hosts).
public struct StaticInstallProvider: EshInstallProviding {
    private let list: [ModelInstall]
    public init(_ list: [ModelInstall]) { self.list = list }
    public func installs() -> [ModelInstall] { list }
}

// MARK: - The facade

public actor EshRuntime {
    private let registry: InferenceBackendRegistry
    private let installProvider: EshInstallProviding
    private let deviceProfileProvider: DeviceProfileProviding
    private let localModelManager: LocalModelManager
    // Multimodal (UCMR) facade wiring. Populated by `makeDefault(...)` / `withEmbeddedGGUF(...)` (or an
    // advanced host via `attachCapabilities`); nil on a bare `EshRuntime()` (text-only, unchanged rc.5 API).
    private var capabilityService: CapabilityExecutionService?
    private var capabilityRegistry: CapabilityRegistry?
    private var persistenceRoot: PersistenceRoot?

    /// Attach an assembled UCMR capability stack (executor + its registry) to this runtime. Called by the
    /// platform default factories after the runtime exists so provider closures can route text inference
    /// back through this runtime. Advanced hosts may call it directly with a hand-built stack.
    public func attachCapabilities(service: CapabilityExecutionService, registry: CapabilityRegistry,
                                   root: PersistenceRoot? = nil) {
        self.capabilityService = service
        self.capabilityRegistry = registry
        if let root { self.persistenceRoot = root }
    }

    /// Actor-isolated accessors used by the `nonisolated` streaming entry point.
    func capabilityServiceRef() -> CapabilityExecutionService? { capabilityService }
    func capabilityRegistryRef() -> CapabilityRegistry? { capabilityRegistry }
    func localModelManagerRef() -> LocalModelManager { localModelManager }

    /// Default construction: the platform backend assembly (iOS → Apple Foundation Models only; macOS →
    /// MLX + GGUF + Apple), the on-disk model store, and the system device-profile provider.
    public init() {
        self.registry = InferenceBackendRegistry()
        self.installProvider = FileInstallProvider()
        self.deviceProfileProvider = SystemDeviceProfileProvider()
        self.localModelManager = LocalModelManager()
    }

    /// Dependency-injected construction for tests and advanced hosts. Provide the backend assembly, the
    /// installed-model source, and (optionally) the device-profile provider directly.
    public init(
        registry: InferenceBackendRegistry,
        installProvider: EshInstallProviding = StaticInstallProvider([]),
        deviceProfileProvider: DeviceProfileProviding = SystemDeviceProfileProvider(),
        localModelManager: LocalModelManager = LocalModelManager()
    ) {
        self.registry = registry
        self.installProvider = installProvider
        self.deviceProfileProvider = deviceProfileProvider
        self.localModelManager = localModelManager
    }

    /// A read-only snapshot of the device/runtime conditions esh is running under (memory, storage,
    /// thermal/low-power state, Apple FM readiness). The app does not gather these signals itself.
    public func deviceProfile() -> DeviceProfile {
        deviceProfileProvider.currentProfile()
    }

    // MARK: - Local model management (M8)

    /// The curated local models and their current install state. The app never touches filesystem paths.
    public func localModels() async -> [LocalModelStatus] {
        await localModelManager.statuses()
    }

    /// Preflight: storage + Model Fit (via the device profile) for a curated model, before downloading.
    public func installPlan(for descriptor: LocalModelDescriptor) async -> LocalModelInstallPlan {
        await localModelManager.installPlan(for: descriptor)
    }

    /// Download → verify (size + SHA-256) → record a curated model as an installed GGUF. Cancelling the
    /// task leaves resumable state and does NOT create an install record.
    @discardableResult
    public func install(_ descriptor: LocalModelDescriptor, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> ModelInstall {
        try await localModelManager.install(descriptor, onProgress: onProgress)
    }

    /// Remove an installed model and all its files.
    public func remove(_ descriptor: LocalModelDescriptor) async throws {
        try await localModelManager.remove(descriptor.id)
    }

    /// Repair the local model store after an interrupted lifecycle (app killed mid download/verify/finalize/
    /// remove). Safe — and recommended — to call once at launch. A model is never reported usable unless its
    /// file verifies (size + SHA-256); interrupted finalizes are recovered, background transfers that
    /// completed while suspended are verified + installed, broken records/dirs are removed, and legitimate
    /// paused/in-flight downloads are preserved. Returns the concrete repairs applied.
    @discardableResult
    public func reconcileLocalModels() async -> LocalModelManager.ReconcileReport {
        await localModelManager.reconcile()
    }

    /// iOS background-download host hook. Forward the app-delegate event
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)` here so esh can finish
    /// delivering background-transfer completions and then call the OS-supplied handler. This is the ONLY
    /// lifecycle integration a host needs for background model downloads; everything else (task↔model
    /// mapping, resume data, staging, checksum verification, install finalization) is internal.
    public func handleBackgroundSessionEvents(identifier: String, completionHandler: @escaping @Sendable () -> Void) async {
        await localModelManager.handleBackgroundSessionEvents(identifier: identifier, completionHandler: completionHandler)
    }

    // MARK: Capabilities

    /// A snapshot of the backends wired on this device and their live availability.
    public func capabilities() -> EshCapabilitySnapshot {
        var backends: [EshBackendAvailability] = []
        for kind in BackendKind.allCases {
            guard let backend = registry.resolve(kind) else { continue }
            let install = Self.probeInstall(for: kind, installProvider: installProvider)
            let report = backend.capabilityReport(for: install)
            backends.append(EshBackendAvailability(backend: kind, report: report, isLocal: Self.isLocal(kind)))
        }
        return EshCapabilitySnapshot(backends: backends, appleIntelligence: AppleIntelligenceService().status())
    }

    // MARK: Generation

    /// One-shot generation. Selects a backend (Auto or pinned), enforces `localOnly`, runs the request
    /// through the existing backend runtime, and returns the assembled text plus selection + metrics.
    public func generate(_ request: EshGenerationRequest) async throws -> EshGenerationResult {
        let plan = try plan(for: request)
        let resolved = try resolveCapabilities(for: request, backend: plan.selection.backend)
        let runtime = try await loadRuntime(plan)
        let session = Self.session(install: plan.install, messages: resolved.messages)
        var text = ""
        do {
            for try await chunk in runtime.generate(session: session, config: resolved.config) {
                try Task.checkCancellation()
                text += chunk
            }
            // An AsyncThrowingStream finishes (returns nil) when the consuming task is cancelled, so the loop
            // can exit without the body running — re-check so a cancelled generation surfaces, not partial text.
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as EshRuntimeError {
            throw e
        } catch {
            throw EshRuntimeError.generationFailed(reason: Self.reason(from: error))
        }
        let metrics = await runtime.metrics
        // §5 reasoning: when thinking is enabled, separate the reasoning chain from the visible answer.
        var visible = text
        var reasoning: String? = nil
        if request.config.enableThinking == true {
            let parsed = ThinkingParser.parse(text)
            visible = parsed.answer ?? ""
            reasoning = parsed.reasoning
        }
        return EshGenerationResult(text: visible, selection: plan.selection, metrics: metrics,
                                   reasoning: reasoning, capabilityResolution: resolved.resolution)
    }

    /// Convenience: generate from a single prompt with Auto selection and default config.
    public func generate(prompt: String) async throws -> EshGenerationResult {
        try await generate(EshGenerationRequest(prompt: prompt))
    }

    // MARK: - Text bridge for UCMR providers

    /// Run a text `ExternalInferenceRequest` through this runtime's selection + backends and return the
    /// assembled response. This is the `InferFn` the portable capability providers (SVG/Web/Project) call —
    /// so they reuse esh's on-device text model with no separate inference stack. `model` maps to a pin
    /// (Auto when nil); everything else (localOnly, generation config) flows through unchanged.
    public func inferText(_ request: ExternalInferenceRequest) async throws -> ExternalInferenceResponse {
        let messages = request.messages.map { Message(role: $0.role, text: $0.text) }
        let constraints: EshConstraints = request.model.map { EshConstraints.pinned($0) } ?? .auto
        let result = try await generate(EshGenerationRequest(messages: messages, constraints: constraints, config: request.generation))
        return ExternalInferenceResponse(
            modelID: result.selection.modelID,
            backend: result.selection.backend,
            integration: ExternalInferenceIntegration(mode: "esh-runtime"),
            outputText: result.text,
            metrics: result.metrics)
    }

    /// Streaming `StreamFn` variant used by `LanguageGenerateProvider` so `language.*` capabilities stream
    /// through the same text path as `stream(_:)`.
    nonisolated func inferStreamText(_ request: ExternalInferenceRequest) -> AsyncThrowingStream<String, Error> {
        let messages = request.messages.map { Message(role: $0.role, text: $0.text) }
        let constraints: EshConstraints = request.model.map { EshConstraints.pinned($0) } ?? .auto
        let gen = EshGenerationRequest(messages: messages, constraints: constraints, config: request.generation)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in self.stream(gen) {
                        if case let .token(t) = event { continuation.yield(t) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Streaming generation. Emits `.token` events as the backend produces text (a single `.token` for
    /// non-streaming backends such as Apple Foundation Models today), then a final `.completed` event.
    /// Cancelling the consuming task stops generation and releases the backend runtime.
    public nonisolated func stream(_ request: EshGenerationRequest) -> AsyncThrowingStream<EshGenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let plan = try await self.plan(for: request)
                    let resolved = try await self.resolveCapabilities(for: request, backend: plan.selection.backend)
                    let runtime = try await self.loadRuntime(plan)
                    let session = EshRuntime.session(install: plan.install, messages: resolved.messages)
                    let thinking = request.config.enableThinking == true
                    var splitter = ReasoningStreamSplitter()
                    var visibleAll = ""
                    var rawAll = ""
                    do {
                        for try await chunk in runtime.generate(session: session, config: resolved.config) {
                            try Task.checkCancellation()
                            rawAll += chunk
                            if thinking {
                                let (v, r) = splitter.ingest(chunk, final: false)
                                if !r.isEmpty { continuation.yield(.reasoningDelta(r)) }
                                if !v.isEmpty { visibleAll += v; continuation.yield(.token(v)) }
                            } else {
                                visibleAll += chunk
                                continuation.yield(.token(chunk))
                            }
                        }
                        if thinking {
                            let (v, r) = splitter.ingest("", final: true)
                            if !r.isEmpty { continuation.yield(.reasoningDelta(r)) }
                            if !v.isEmpty { visibleAll += v; continuation.yield(.token(v)) }
                        }
                        try Task.checkCancellation()
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let e as EshRuntimeError {
                        throw e
                    } catch {
                        throw EshRuntimeError.generationFailed(reason: EshRuntime.reason(from: error))
                    }
                    let metrics = await runtime.metrics
                    // Authoritative split for the final result — handles explicit AND implicit-open formats.
                    var finalText = visibleAll
                    var finalReasoning: String? = nil
                    if thinking {
                        let parsed = ThinkingParser.parse(rawAll)
                        finalText = parsed.answer ?? ""
                        finalReasoning = parsed.reasoning
                    }
                    let result = EshGenerationResult(
                        text: finalText, selection: plan.selection, metrics: metrics,
                        reasoning: finalReasoning, capabilityResolution: resolved.resolution)
                    continuation.yield(.completed(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Selection (thin, over the existing registry — NOT a parallel router)

    private struct Plan {
        let install: ModelInstall
        let backend: any InferenceBackend
        let selection: EshSelection
    }

    /// Resolve the request to a concrete (install, backend) using the existing registry + install store.
    /// Honors an explicit pin (never substituted), Auto (Apple-first zero-download, then installed models),
    /// and the hard `localOnly` constraint. Actor-isolated and synchronous (capability reports are sync).
    private func plan(for request: EshGenerationRequest) throws -> Plan {
        if let pinned = request.constraints.pinnedModelID {
            return try planPinned(pinned, constraints: request.constraints)
        }
        return try planAuto(constraints: request.constraints)
    }

    private func planPinned(_ modelID: String, constraints: EshConstraints) throws -> Plan {
        // Apple pinned explicitly.
        if AppleProvider.isAppleModelID(modelID) {
            guard let backend = registry.resolve(.apple) else {
                throw EshRuntimeError.pinnedModelUnavailable(modelID: modelID, reason: "Apple backend is not available on this platform.")
            }
            let install = AppleProvider.syntheticInstall()
            try ensureReady(backend, install: install, pinned: modelID)
            try ensureLocal(.apple)
            return Plan(install: install, backend: backend,
                        selection: EshSelection(backend: .apple, modelID: install.id, reason: "explicit Apple pin", localOnlySatisfied: true))
        }
        // A pinned downloaded model: find it in the store. It is NEVER substituted with Apple.
        guard let install = installProvider.installs().first(where: { $0.id == modelID }) else {
            throw EshRuntimeError.pinnedModelUnavailable(modelID: modelID, reason: "not installed on this device (esh does not substitute another provider for a pinned model).")
        }
        guard let backend = registry.resolve(install.spec.backend) else {
            throw EshRuntimeError.backendUnavailable(install.spec.backend, reason: "the backend for pinned model '\(modelID)' is not available on this platform.")
        }
        try ensureReady(backend, install: install, pinned: modelID)
        try ensureLocal(install.spec.backend)
        return Plan(install: install, backend: backend,
                    selection: EshSelection(backend: install.spec.backend, modelID: install.id, reason: "explicit model pin", localOnlySatisfied: true))
    }

    private func planAuto(constraints: EshConstraints) throws -> Plan {
        // Candidate order: Apple Foundation Models first (zero-download, on-device), then installed models
        // whose backend is wired on this platform. This reuses the registry's candidate set — it does not
        // introduce a second routing system; richer scheduler/Model-Fit routing can be injected later.
        var candidates: [(BackendKind, ModelInstall, String)] = []
        if registry.resolve(.apple) != nil {
            candidates.append((.apple, AppleProvider.syntheticInstall(), "no-download on-device provider available"))
        }
        for install in installProvider.installs() where registry.resolve(install.spec.backend) != nil {
            candidates.append((install.spec.backend, install, "auto-selected installed model"))
        }
        guard !candidates.isEmpty else {
            throw EshRuntimeError.noAvailableBackend(reason: "no backend is wired on this platform.")
        }
        for (kind, install, reason) in candidates {
            guard Self.isLocal(kind) || !constraints.localOnly else { continue }
            guard let backend = registry.resolve(kind) else { continue }
            if backend.capabilityReport(for: install).ready {
                return Plan(install: install, backend: backend,
                            selection: EshSelection(backend: kind, modelID: install.id, reason: reason, localOnlySatisfied: true))
            }
        }
        // Nothing was ready — surface the honest reason from the preferred candidate.
        let (kind, install, _) = candidates[0]
        let report = registry.resolve(kind)?.capabilityReport(for: install)
        let detail = report?.warnings.first ?? report?.unavailableFeatures.first?.reason ?? "no ready backend on this device."
        throw EshRuntimeError.noAvailableBackend(reason: detail)
    }

    private func ensureReady(_ backend: any InferenceBackend, install: ModelInstall, pinned: String) throws {
        let report = backend.capabilityReport(for: install)
        guard report.ready else {
            let detail = report.warnings.first ?? report.unavailableFeatures.first?.reason ?? "backend not ready."
            throw EshRuntimeError.pinnedModelUnavailable(modelID: pinned, reason: detail)
        }
    }

    private func ensureLocal(_ kind: BackendKind) throws {
        guard Self.isLocal(kind) else {
            throw EshRuntimeError.localOnlyViolation(reason: "backend '\(kind.rawValue)' does not execute locally.")
        }
    }

    // MARK: - Helpers

    /// Every backend esh ships today executes locally/on-device (Apple FM on-device; MLX/GGUF run local
    /// models). esh has no remote backend, so `localOnly` is always satisfiable. This is the single place
    /// locality is decided, so a future remote provider only needs updating here.
    static func isLocal(_ kind: BackendKind) -> Bool {
        switch kind {
        case .apple, .mlx, .gguf, .onnx: return true
        }
    }

    /// A representative install for probing a backend's capability report.
    static func probeInstall(for kind: BackendKind, installProvider: EshInstallProviding) -> ModelInstall {
        if kind == .apple { return AppleProvider.syntheticInstall() }
        if let install = installProvider.installs().first(where: { $0.spec.backend == kind }) { return install }
        return AppleProvider.syntheticInstall()
    }

    static func session(install: ModelInstall, messages: [Message]) -> ChatSession {
        ChatSession(name: "esh-runtime", modelID: install.id, backend: install.spec.backend, messages: messages)
    }

    /// Load the runtime for a plan, mapping non-typed load failures to a typed `modelLoadFailed`.
    private func loadRuntime(_ plan: Plan) async throws -> any BackendRuntime {
        do { return try await plan.backend.loadRuntime(for: plan.install) }
        catch is CancellationError { throw CancellationError() }
        catch { throw EshRuntimeError.modelLoadFailed(modelID: plan.install.id, reason: Self.reason(from: error)) }
    }

    /// Resolve `responseFormat`/`tools` against the selected backend (§5). Returns the (possibly augmented)
    /// messages, the (possibly constrained) config, and the honest resolution. When neither is requested the
    /// inputs pass through unchanged (identical to the pre-§5 path — no behavior change for plain text).
    func resolveCapabilities(for request: EshGenerationRequest, backend: BackendKind) throws
        -> (messages: [Message], config: GenerationConfig, resolution: CapabilityResolution?) {
        guard request.responseFormat != nil || (request.tools?.isEmpty == false) else {
            return (request.messages, request.config, nil)
        }
        let outcome = CapabilityResolver().resolve(
            responseFormat: request.responseFormat, backend: backend,
            tools: request.tools, reasoningEnabled: request.config.enableThinking)
        if request.responseFormat?.strict == true, outcome.resolution.hasRejections {
            let detail = outcome.resolution.first(named: "response_format")?.detail ?? "not supported"
            throw EshRuntimeError.generationFailed(reason: "strict structured output rejected: \(detail)")
        }
        var messages = request.messages
        if let aug = outcome.systemInstructionAugmentation { messages.insert(Message(role: .system, text: aug), at: 0) }
        var config = request.config
        if let schema = outcome.nativeJSONSchema { config.jsonSchema = schema }
        if let grammar = outcome.nativeGrammar { config.grammar = grammar }
        return (messages, config, outcome.resolution)
    }

    /// Human-readable reason for a non-typed backend error, kept as display text on a typed case so the
    /// host never has to parse it to branch. Prefers `LocalizedError.errorDescription`.
    static func reason(from error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}

// MARK: - Multimodal (UCMR) capability facade (§1/§6)
//
// Additive to the text API. `execute`/`stream(ExecutionRequest)` run any wired capability (OCR, SVG, Web,
// Code today; image/audio/… as providers are wired per platform) through the EshCore
// `CapabilityExecutionService`; `capabilityAvailability()` reports honest per-capability states; and
// `makeDefault(...)` assembles a runtime with the portable providers so a consumer never hand-builds a
// registry. A bare `EshRuntime()` has no providers wired and these throw a clear typed error.

public extension EshRuntime {
    /// Run a capability request to completion, folding its event stream into an `ExecutionResult`
    /// (accumulated text + produced artifacts + usage). Throws `CapabilityError.unsupported` when no
    /// provider is wired for the capability (or none at all — build the runtime with `makeDefault`).
    /// Public so a consumer can invoke non-text capabilities (e.g. macOS compatibility image.generate/
    /// image.edit) through the facade without reaching into internals.
    func execute(_ request: ExecutionRequest) async throws -> ExecutionResult {
        guard let service = capabilityService else {
            throw CapabilityError.unsupported(capability: request.capability.rawValue,
                detail: "no capability providers are wired on this EshRuntime (build it with EshRuntime.makeDefault()).")
        }
        return try await service.executeCollecting(request)
    }

    /// Stream a capability request's events (`.textDelta`/`.reasoningDelta`/`.progress`/`.artifactProduced`/
    /// `.previewReady`/`.usage`/`.done`/`.failed`). Cancelling the consuming task cancels the provider —
    /// the same cooperative-cancellation contract as the text `stream(_:)`.
    nonisolated func stream(_ request: ExecutionRequest) -> AsyncThrowingStream<CapabilityEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let service = await self.capabilityServiceRef() else {
                    continuation.finish(throwing: CapabilityError.unsupported(capability: request.capability.rawValue,
                        detail: "no capability providers are wired on this EshRuntime (build it with EshRuntime.makeDefault())."))
                    return
                }
                do {
                    for try await event in service.execute(request) {
                        try Task.checkCancellation()
                        continuation.yield(event)
                    }
                    try Task.checkCancellation()
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Refresh runtime-stateful providers' cached availability from a live preflight, so the next
    /// `capabilityAvailability()` reflects real engine states (installed / repairRequired / ready). Safe to
    /// call at launch and after installs; cheap for native providers (no-op).
    func refreshCapabilityAvailability() async {
        for provider in capabilityRegistry?.all ?? [] {
            if let refreshing = provider as? CapabilityAvailabilityRefreshing { await refreshing.refreshAvailability() }
        }
    }

    /// Honest per-capability availability for this device/platform (§6). Registry-driven: a capability is
    /// `.ready` only when a provider is wired and anything it needs (a text model) is ready; unwired
    /// capabilities report `.unsupportedOnPlatform` (families that cannot run here) or `.comingLater`.
    func capabilityAvailability() -> CapabilityAvailabilitySnapshot {
        let registered = Set((capabilityRegistry?.all ?? []).flatMap { $0.descriptor.capabilities })
        let snapshot = capabilities()
        let anyTextBackendWired = !snapshot.backends.isEmpty
        let textReady = snapshot.hasReadyBackend

        // Capabilities whose provider needs a text model (they prompt an LLM).
        let textDependent: Set<CapabilityID> = [.languageGenerate, .vectorGenerate, .webArtifactGenerate, .projectGenerate]
        // Families that today require a macOS/Python(MLX) runtime — not available to a portable consumer on
        // iOS. (image.segment is NOT here: it's now a native Vision provider, portable to iOS.)
        // (image.understand is NOT here: it's now a native MLX-Swift provider via the opt-in EshVision
        // product, portable to iOS + macOS. image.segment is native Vision. The rest remain macOS-only
        // compatibility engines today.)
        // (image.upscale is NOT here: it's now a native MetalFX/Core Image provider, portable to iOS + macOS.)
        let macOSOnly: Set<CapabilityID> = [
            .imageGenerate, .imageEdit,
            .audioGenerate, .musicGenerate, .audioDiarize, .videoUnderstand
        ]
        // The full set the SDK models today (so the app can render every mode's state).
        // image.restyle is a native (EshImageGen, macOS+iOS) fast img2img — NOT in macOSOnly, distinct from
        // the content-preserving instruct `image.edit` (a macOS-only compat engine today).
        let known: [CapabilityID] = [
            .languageGenerate, .vectorGenerate, .webArtifactGenerate, .projectGenerate,
            .imageOCR, .imageUnderstand,
            .imageGenerate, .imageEdit, .imageRestyle, .imageUpscale, .imageSegment,
            .audioTranscribe, .audioSynthesizeSpeech, .audioGenerate, .musicGenerate, .audioDiarize,
            .videoUnderstand
        ]

        // Providers whose availability is runtime-stateful (e.g. macOS compatibility engines) report it
        // directly; that wins over the static classification below. Native (in-process) reporters are
        // consulted BEFORE the Python compat bridge so discovery matches execution: when both a native and a
        // compat provider exist for a capability, the native one's state is reported (it's the one that runs).
        let allRegistered = capabilityRegistry?.all ?? []
        let reporters = (allRegistered.filter { $0.descriptor.backend.isInProcess }
                       + allRegistered.filter { !$0.descriptor.backend.isInProcess })
            .compactMap { $0 as? CapabilityAvailabilityReporting }
        func reported(_ cap: CapabilityID) -> CapabilityAvailability? {
            for reporter in reporters { if let state = reporter.reportedAvailability(for: cap) { return state } }
            return nil
        }

        func classify(_ cap: CapabilityID) -> CapabilityAvailability {
            if let state = reported(cap) { return state }
            if registered.contains(cap) {
                if cap == .imageOCR { return .ready }               // Apple Vision — zero-dependency, on-device
                if cap == .audioTranscribe { return Self.speechRecognitionAvailability() }
                if textDependent.contains(cap) {
                    if textReady { return .ready }
                    return anyTextBackendWired
                        ? .temporarilyUnavailable(reason: "no text model is ready yet")
                        : .requiresDownload(modelID: nil, bytes: nil)
                }
                return .ready
            }
            #if os(iOS) || os(tvOS) || os(watchOS)
            if macOSOnly.contains(cap) { return .unsupportedOnPlatform }
            #endif
            return .comingLater
        }

        var entries: [CapabilityID: CapabilityAvailability] = [:]
        for cap in known { entries[cap] = classify(cap) }
        return CapabilityAvailabilitySnapshot(entries: entries)
    }

    /// Whether a capability can produce multiple candidate outputs (variants) in one execution, and the max
    /// esh will produce — aggregated over the capability's providers, so a consumer never hardcodes model
    /// knowledge. `maxCount` is 1 for single-output capabilities. (rc.22)
    func outputCapability(for capability: CapabilityID) -> (supportsMultiple: Bool, maxCount: Int) {
        let providers = (capabilityRegistry?.all ?? []).filter { $0.descriptor.capabilities.contains(capability) }
        let maxCount = providers.map { $0.descriptor.maximumOutputCount }.max() ?? 1
        let supportsMultiple = providers.contains { $0.descriptor.supportsMultipleOutputs }
        return (supportsMultiple, max(1, maxCount))
    }

    // MARK: - Runtime resource state (rc.21)

    /// The heavy models/runtimes esh is currently keeping resident, with truthful per-model facts. Reports
    /// only what esh genuinely knows: providers that publish runtime state (the native image tiers today).
    /// LLM/text residency is not tracked at this layer, so those are omitted rather than guessed;
    /// `measuredMemoryBytes` is nil unless esh has a real measurement.
    func residentModels() -> [ResidentModel] {
        capabilityRegistry?.residentModels() ?? []
    }

    /// Device resource facts for a consumer's headroom reasoning: memory + per-volume free space, plus esh's
    /// own memory-pressure judgment. System volume = the internal state root (swap headroom); assets volume =
    /// the configured model store.
    func resourcePressure() -> ResourcePressureSnapshot {
        let p = deviceProfileProvider.currentProfile()
        let total = Int64(p.physicalMemoryBytes)
        let available = p.availableMemoryBytes.map(Int64.init)
        let root = persistenceRoot ?? .default()
        let systemFree = SystemStorage.snapshot(at: root.stateRootURL)?.availableBytes
        let assetsFree = StorageService().availability(root: root).freeBytes
        // esh's pressure judgment: thermal-critical, or available memory below a safe floor (2 GB or 10%).
        let floor = max(Int64(2) * 1_073_741_824, total / 10)
        let memoryCritical = (p.thermalState == .critical) || (available.map { $0 < floor } ?? false)
        return ResourcePressureSnapshot(totalMemoryBytes: total, availableMemoryBytes: available,
                                        memoryCritical: memoryCritical,
                                        systemVolumeFreeBytes: systemFree, assetsVolumeFreeBytes: assetsFree)
    }

    /// Explicitly unload one resident model by its id (the pinning id from `residentModels()`). An **active**
    /// model is never force-unloaded — it throws `UnloadError.modelActive`. Unknown ids throw
    /// `.unknownModel`; a model that is already not resident is a no-op (idempotent).
    func unload(modelID: String) async throws {
        guard let registry = capabilityRegistry,
              let provider = registry.all.first(where: { $0.descriptor.id == modelID }) else {
            throw UnloadError.unknownModel(modelID)
        }
        if let reporting = provider as? ResourceStateReporting {
            let state = reporting.resourceState
            if state.active { throw UnloadError.modelActive(modelID) }
            if !state.warm { return }   // already released — nothing to do
        }
        await provider.unload()
    }

    /// Release every resident model that is warm/idle but not currently serving a request. Active models are
    /// left untouched. Best-effort memory reclaim for low-headroom situations.
    func unloadIdleRuntimes() async {
        guard let registry = capabilityRegistry else { return }
        let idle = Set(registry.idleUnloadableProviderIDs())
        for provider in registry.all where idle.contains(provider.descriptor.id) {
            await provider.unload()
        }
    }

    /// Assemble a runtime with the platform's text backend(s) AND the portable capability providers
    /// (OCR + SVG + Web + Code + text) wired behind the `execute`/`stream` facade. iOS gets Apple
    /// Foundation Models text by default; richer/GGUF/macOS assemblies inject more `backends` and
    /// `additionalProviders`. The provider text closure routes back through this runtime, so there is no
    /// second inference stack.
    static func makeDefault(
        backends: [BackendKind: any InferenceBackend] = [.apple: AppleBackend()],
        root: PersistenceRoot = .default(),
        installProvider: EshInstallProviding = FileInstallProvider(),
        deviceProfileProvider: DeviceProfileProviding = SystemDeviceProfileProvider(),
        localModelManager: LocalModelManager = LocalModelManager(),
        additionalProviders: [any CapabilityProvider] = []
    ) async -> EshRuntime {
        let runtime = EshRuntime(
            registry: InferenceBackendRegistry(backends: backends),
            installProvider: installProvider,
            deviceProfileProvider: deviceProfileProvider,
            localModelManager: localModelManager
        )
        let infer: @Sendable (ExternalInferenceRequest) async throws -> ExternalInferenceResponse = { [weak runtime] req in
            guard let runtime else { throw CapabilityError.failed("EshRuntime was released before inference.") }
            return try await runtime.inferText(req)
        }
        let stream: @Sendable (ExternalInferenceRequest) -> AsyncThrowingStream<String, Error> = { [weak runtime] req in
            guard let runtime else {
                return AsyncThrowingStream { $0.finish(throwing: CapabilityError.failed("EshRuntime was released before inference.")) }
            }
            return runtime.inferStreamText(req)
        }

        var registry = CapabilityRegistry()
        registry.register(LanguageGenerateProvider(stream: stream))
        registry.register(AppleVisionOCRProvider())
        registry.register(AppleVisionSegmentationProvider())   // §3/§10 native background removal
        registry.register(AppleImageUpscaleProvider())         // §3 native upscale (MetalFX + Lanczos fallback)
        registry.register(TextToSVGProvider(infer: infer))
        registry.register(WebArtifactProvider(infer: infer))
        registry.register(ProjectGenProvider(infer: infer))
        // §4 — portable on-device speech (Apple frameworks; no model download).
        registry.register(AppleSpeechSynthesizeProvider())
        registry.register(AppleSpeechTranscribeProvider())
        for provider in additionalProviders { registry.register(provider) }

        let context = ExecutionContext(root: root, artifactStore: FileArtifactStore(root: root))
        // Resource-aware Auto routing: read the live machine (memory + per-volume disk + swap headroom) once
        // per request, and report each provider's install/warm state (for anti-flapping + warm reuse).
        let resourceHost: @Sendable () -> HostResources = {
            HostResourceProbe.snapshot(root: root, deviceProfile: deviceProfileProvider)
        }
        let allProviders = registry.all
        let providerState: @Sendable (String) -> ProviderRuntimeState = { id in
            (allProviders.first { $0.descriptor.id == id } as? ResourceStateReporting)?.resourceState ?? .init()
        }
        let service = CapabilityExecutionService(registry: registry, context: context,
                                                 resourceHost: resourceHost, providerState: providerState)
        await runtime.attachCapabilities(service: service, registry: registry, root: root)
        return runtime
    }

    /// Honest availability for on-device speech recognition (§4/§6): ready when authorized (or not yet
    /// asked — the provider prompts on first use), unsupported when the user denied it or the device has no
    /// recognizer, and unsupported-on-platform where the Speech framework is absent.
    static func speechRecognitionAvailability() -> CapabilityAvailability {
        #if canImport(Speech)
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized, .notDetermined: return .ready
        case .denied, .restricted: return .unsupportedOnDevice(reason: "speech recognition permission is not granted")
        @unknown default: return .temporarilyUnavailable(reason: "speech recognition status is unknown")
        }
        #else
        return .unsupportedOnPlatform
        #endif
    }
}
