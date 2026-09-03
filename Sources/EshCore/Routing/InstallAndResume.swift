import Foundation

// esh 2.1 — Install-and-Resume (spec 86eyucfbu §10). When a supported capability's component is missing,
// esh records a PendingCapabilityInvocation, surfaces an install card, and — after the user installs the
// component — automatically resumes the ORIGINAL request so the user never has to repeat it.
//
// Persistence: pending invocations are held IN MEMORY for the server's lifetime. They survive UI updates
// and install progress, but NOT a server restart (honest limitation for this first cut; a durable store
// can back the same interface later).

public struct PendingCapabilityInvocation: Sendable, Identifiable, Equatable {
    public let id: UUID
    public var message: String
    public var attachments: [EshAttachment]
    public var intent: CapabilityIntent
    public var requirement: InstallRequirement
    public var conversationID: String?
    public var createdAtISO8601: String
    public init(id: UUID = UUID(), message: String, attachments: [EshAttachment], intent: CapabilityIntent,
                requirement: InstallRequirement, conversationID: String? = nil, createdAtISO8601: String) {
        self.id = id; self.message = message; self.attachments = attachments; self.intent = intent
        self.requirement = requirement; self.conversationID = conversationID; self.createdAtISO8601 = createdAtISO8601
    }
}

/// In-memory store of pending invocations (see persistence note above).
public actor PendingInvocationStore {
    private var pending: [UUID: PendingCapabilityInvocation] = [:]
    public init() {}
    public func put(_ p: PendingCapabilityInvocation) { pending[p.id] = p }
    public func get(_ id: UUID) -> PendingCapabilityInvocation? { pending[id] }
    public func remove(_ id: UUID) { pending[id] = nil }
    public func all() -> [PendingCapabilityInvocation] { Array(pending.values) }
}

public enum ResumeResult: Sendable {
    case executed(ExecutionResult)
    case stillMissing(InstallRequirement)   // component still not present after the install attempt
    case noLongerApplicable(RoutingOutcome) // request now resolves to something else (e.g. clarify)
    case notFound
}

/// Orchestrates record → (external install) → resume. Pure of the actual installer: the caller performs the
/// install (with Model Fit / disk / storage confirmation) and then calls `resume` with fresh install state.
public struct InstallAndResumeService: Sendable {
    private let store: PendingInvocationStore
    private let resolver: IntentResolver
    public init(store: PendingInvocationStore, resolver: IntentResolver = .init()) {
        self.store = store; self.resolver = resolver
    }

    /// Record a pending invocation from an installRequired outcome so the ORIGINAL request can be resumed.
    public func record(message: String, attachments: [EshAttachment], intent: CapabilityIntent,
                       requirement: InstallRequirement, conversationID: String?, nowISO8601: String) async -> PendingCapabilityInvocation {
        let p = PendingCapabilityInvocation(message: message, attachments: attachments, intent: intent,
                                            requirement: requirement, conversationID: conversationID, createdAtISO8601: nowISO8601)
        await store.put(p)
        return p
    }

    /// Resume a pending invocation after its component was installed: re-validate the ORIGINAL request with
    /// fresh install state and, if now ready, execute it — result lands in the same conversation.
    public func resume(_ id: UUID, registry: CapabilityRegistry, installs: [ModelInstall], root: PersistenceRoot,
                       host: HostMachineProfile? = nil,
                       execute: @Sendable (ExecutionRequest) async throws -> ExecutionResult) async rethrows -> ResumeResult {
        guard let p = await store.get(id) else { return .notFound }
        let outcome = resolver.resolve(message: p.message, attachments: p.attachments,
                                       registry: registry, installs: installs, root: root, host: host)
        switch outcome {
        case let .ready(request, _):
            let result = try await execute(request)
            await store.remove(id)
            return .executed(result)
        case let .installRequired(_, _, requirement):
            return .stillMissing(requirement)   // keep the pending for another attempt
        default:
            await store.remove(id)
            return .noLongerApplicable(outcome)
        }
    }
}
