import Foundation

// esh 2.1 — the service behind POST /v1/route (and /v1/route/resume). Turns a chat message + typed
// attachments into a serializable RouteDecision the client can act on: run it now, show an install card,
// clarify, or treat as ordinary chat. Wraps IntentResolver + a PendingInvocationStore for Install-and-Resume.

/// Serializable routing decision for clients (web/API). For `ready` and `installRequired` it carries the
/// built ExecutionRequest so the client runs it via the existing POST /v1/execute (one execution path).
public struct RouteDecision: Codable, Sendable {
    public var action: String                 // chat | ready | installRequired | clarify | unsupported
    public var capability: String?
    public var request: ExecutionRequest?     // for ready / installRequired (run after install)
    public var installRequirement: InstallRequirement?
    public var pendingId: String?
    public var reason: String?
    public var alternatives: [String]
    public var provenance: RouterProvenance?
    /// Human-facing routing explanation for the Execution Inspector (spec §12). Hidden for ordinary users.
    public var explanation: String?

    public init(action: String, capability: String? = nil, request: ExecutionRequest? = nil,
                installRequirement: InstallRequirement? = nil, pendingId: String? = nil, reason: String? = nil,
                alternatives: [String] = [], provenance: RouterProvenance? = nil, explanation: String? = nil) {
        self.action = action; self.capability = capability; self.request = request
        self.installRequirement = installRequirement; self.pendingId = pendingId; self.reason = reason
        self.alternatives = alternatives; self.provenance = provenance; self.explanation = explanation
    }
}

/// POST /v1/route body.
public struct RouteHTTPRequest: Codable, Sendable {
    public var message: String
    public var attachments: [EshAttachment]?
    public var conversationID: String?
    public init(message: String, attachments: [EshAttachment]? = nil, conversationID: String? = nil) {
        self.message = message; self.attachments = attachments; self.conversationID = conversationID
    }
}

/// POST /v1/route/resume body.
public struct RouteResumeHTTPRequest: Codable, Sendable {
    public var pendingId: String
    public var conversationID: String?
    public init(pendingId: String, conversationID: String? = nil) { self.pendingId = pendingId; self.conversationID = conversationID }
}

public struct CapabilityRouterService: Sendable {
    private let resolver: IntentResolver
    private let store: PendingInvocationStore
    private let registry: @Sendable () -> CapabilityRegistry
    private let installs: @Sendable () -> [ModelInstall]
    private let root: PersistenceRoot
    private let host: @Sendable () -> HostMachineProfile?
    private let now: @Sendable () -> String
    /// The Tier-1 semantic router (for benchmarking each router in isolation and the hybrid).
    private let semantic: SemanticIntentRouter?
    private let tier0 = DeterministicIntentRouter()

    public init(resolver: IntentResolver = .init(), store: PendingInvocationStore,
                registry: @escaping @Sendable () -> CapabilityRegistry,
                installs: @escaping @Sendable () -> [ModelInstall],
                root: PersistenceRoot,
                host: @escaping @Sendable () -> HostMachineProfile? = { nil },
                semantic: SemanticIntentRouter? = nil,
                now: @escaping @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) }) {
        self.resolver = resolver; self.store = store; self.registry = registry
        self.installs = installs; self.root = root; self.host = host; self.semantic = semantic; self.now = now
    }

    /// Run the routing benchmark for one router mode ("tier0" | "tier1" | "hybrid") over the full multilingual
    /// dataset, with live inference for the semantic tiers. Returns metrics + the median warm latency. Used by
    /// POST /v1/route/benchmark to produce versioned Router Auto evidence.
    public func benchmark(mode: String, semanticOverride: SemanticIntentRouter? = nil) async -> (metrics: RoutingMetrics, warmLatencyMsMedian: Double?, coldLatencyMs: Double?) {
        let cases = RoutingDataset.all
        if mode == "tier0" { return (RoutingBenchmark.run(cases), 0, 0) }
        let reg = registry()
        let schema = CapabilitySchemaBuilder.build(from: reg)
        let latencies = LatencyBox()
        // Pick the semantic router by mode: an explicit override (e.g. FunctionGemma) wins; else apple* →
        // Apple Foundation Models; else the resident LLM.
        let sem: SemanticIntentRouter? = semanticOverride ?? (mode.hasPrefix("apple") ? AppleFMSemanticRouter() : semantic)
        let tier1Only = (mode == "tier1" || mode == "apple")
        let t0 = tier0
        let metrics = await RoutingBenchmark.runRouter(cases) { message, mods in
            let start = Date()
            if tier1Only {
                let intent = (await sem?.propose(message: message, inputModalities: mods, schema: schema))
                    ?? CapabilityIntent(action: .clarify, provenance: .init(tier: "tier1-semantic", router: sem?.name ?? "none"))
                await latencies.add(Date().timeIntervalSince(start) * 1000)
                return intent
            }
            // hybrid: Tier-0 first; escalate to Tier-1 only on clarify; validate the proposal is registered.
            var intent = t0.route(message: message, inputModalities: mods)
            if intent.action == .clarify, let sem {
                if let p = await sem.propose(message: message, inputModalities: mods, schema: schema),
                   p.action == .executeCapability, let cap = p.capability,
                   reg.all.contains(where: { $0.descriptor.capabilities.contains(cap) }) {
                    intent = p
                }
                await latencies.add(Date().timeIntervalSince(start) * 1000)   // only escalated cases pay LLM cost
            }
            return intent
        }
        // Cold = the first escalated call (pays model load); warm median = the rest (steady state).
        return (metrics, await latencies.warmMedian(), await latencies.cold())
    }

    /// Choose the Tier-1 router from persisted evidence (Router Auto), explaining why.
    public func routerAuto(currentOS: String?, eshVersion: String?) -> RouterAutoPolicy.Decision {
        let ev = RouterEvidenceStore(root: root).load().evidence
        return RouterAutoPolicy().choose(from: ev, currentSchemaVersion: CapabilitySchemaVersion.current,
                                         currentDatasetVersion: RoutingBenchmark.datasetVersion, currentOS: currentOS)
    }

    actor LatencyBox {
        var xs: [Double] = []
        func add(_ x: Double) { xs.append(x) }
        /// The first sample — includes model cold-load, so it's the honest "cold" number.
        func cold() -> Double? { xs.first }
        /// Median of the warm (steady-state) samples: drops the first (cold) sample when we have >1.
        func warmMedian() -> Double? {
            guard !xs.isEmpty else { return nil }
            let warm = xs.count > 1 ? Array(xs.dropFirst()) : xs
            let s = warm.sorted(); return s[s.count/2]
        }
    }

    public func route(message: String, attachments: [EshAttachment], conversationID: String?) async -> RouteDecision {
        let outcome = await resolver.resolve(message: message, attachments: attachments,
                                       registry: registry(), installs: installs(), root: root, host: host())
        return await decision(from: outcome, message: message, attachments: attachments, conversationID: conversationID)
    }

    /// Re-validate a pending invocation with fresh install state (after the component was installed).
    public func resume(pendingId: String, conversationID: String?) async -> RouteDecision {
        guard let id = UUID(uuidString: pendingId), let p = await store.get(id) else {
            return RouteDecision(action: "unsupported", reason: "This request is no longer pending (it may have expired on a server restart).")
        }
        let outcome = await resolver.resolve(message: p.message, attachments: p.attachments,
                                       registry: registry(), installs: installs(), root: root, host: host())
        if case .ready = outcome { await store.remove(id) }
        return await decision(from: outcome, message: p.message, attachments: p.attachments, conversationID: conversationID, reuseId: id)
    }

    private func decision(from outcome: RoutingOutcome, message: String, attachments: [EshAttachment],
                          conversationID: String?, reuseId: UUID? = nil) async -> RouteDecision {
        switch outcome {
        case .chat:
            return RouteDecision(action: "chat")
        case let .ready(request, intent):
            var d = RouteDecision(action: "ready", capability: intent.capability?.rawValue, request: request, provenance: intent.provenance)
            d.explanation = "Resolved as \(intent.capability?.rawValue ?? "?") · \(intent.provenance.tier) (\(intent.provenance.router)) · validated by the capability registry"
            return d
        case let .installRequired(request, intent, requirement):
            let pending = PendingCapabilityInvocation(id: reuseId ?? UUID(), message: message, attachments: attachments,
                                                      intent: intent, requirement: requirement, conversationID: conversationID,
                                                      createdAtISO8601: now())
            await store.put(pending)
            return RouteDecision(action: "installRequired", capability: intent.capability?.rawValue, request: request,
                                 installRequirement: requirement, pendingId: pending.id.uuidString, provenance: intent.provenance)
        case let .clarify(reason, alternatives):
            return RouteDecision(action: "clarify", reason: reason, alternatives: alternatives.map { $0.rawValue })
        case let .unsupported(reason):
            return RouteDecision(action: "unsupported", reason: reason)
        }
    }
}
