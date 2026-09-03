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

    public init(action: String, capability: String? = nil, request: ExecutionRequest? = nil,
                installRequirement: InstallRequirement? = nil, pendingId: String? = nil, reason: String? = nil,
                alternatives: [String] = [], provenance: RouterProvenance? = nil) {
        self.action = action; self.capability = capability; self.request = request
        self.installRequirement = installRequirement; self.pendingId = pendingId; self.reason = reason
        self.alternatives = alternatives; self.provenance = provenance
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

    public init(resolver: IntentResolver = .init(), store: PendingInvocationStore,
                registry: @escaping @Sendable () -> CapabilityRegistry,
                installs: @escaping @Sendable () -> [ModelInstall],
                root: PersistenceRoot,
                host: @escaping @Sendable () -> HostMachineProfile? = { nil },
                now: @escaping @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) }) {
        self.resolver = resolver; self.store = store; self.registry = registry
        self.installs = installs; self.root = root; self.host = host; self.now = now
    }

    public func route(message: String, attachments: [EshAttachment], conversationID: String?) async -> RouteDecision {
        let outcome = resolver.resolve(message: message, attachments: attachments,
                                       registry: registry(), installs: installs(), root: root, host: host())
        return await decision(from: outcome, message: message, attachments: attachments, conversationID: conversationID)
    }

    /// Re-validate a pending invocation with fresh install state (after the component was installed).
    public func resume(pendingId: String, conversationID: String?) async -> RouteDecision {
        guard let id = UUID(uuidString: pendingId), let p = await store.get(id) else {
            return RouteDecision(action: "unsupported", reason: "This request is no longer pending (it may have expired on a server restart).")
        }
        let outcome = resolver.resolve(message: p.message, attachments: p.attachments,
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
            return RouteDecision(action: "ready", capability: intent.capability?.rawValue, request: request, provenance: intent.provenance)
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
