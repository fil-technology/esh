import Foundation

// esh 2.1 — independent intent validation + outcome resolution (spec 86eyucfbu §1/§8/§9). Routes a chat
// message + typed attachments (Tier 0 today; Tier 1 pluggable later) into a CapabilityIntent, then
// validates it against the registry / installed state / assets — the router is NEVER the authority — and
// returns a RoutingOutcome (chat | ready | installRequired | clarify | unsupported).

public struct IntentResolver: Sendable {
    private let router: DeterministicIntentRouter
    /// Optional Tier-1 semantic router, consulted only when Tier 0 is unsure (clarify). Its proposal is
    /// validated exactly like Tier 0 — the router is never the authority (spec §1/§8).
    private let semantic: SemanticIntentRouter?
    public init(router: DeterministicIntentRouter = .init(), semantic: SemanticIntentRouter? = nil) {
        self.router = router; self.semantic = semantic
    }

    public func resolve(message: String, attachments: [EshAttachment],
                        registry: CapabilityRegistry, installs: [ModelInstall],
                        root: PersistenceRoot, host: HostMachineProfile? = nil) async -> RoutingOutcome {
        let modalities = attachments.map(Self.modality)
        var intent = router.route(message: message, inputModalities: modalities)

        // Tier 1 escalation: only when Tier 0 couldn't decide (clarify). Keeps LLM calls rare, and the
        // semantic proposal must name a REGISTERED capability or we keep Tier 0's clarify (no false exec).
        if intent.action == .clarify, let semantic {
            let schema = CapabilitySchemaBuilder.build(from: registry)
            if let proposal = await semantic.propose(message: message, inputModalities: modalities, schema: schema),
               proposal.action == .executeCapability, let cap = proposal.capability,
               registry.all.contains(where: { $0.descriptor.capabilities.contains(cap) }) {
                intent = proposal
            }
        }

        switch intent.action {
        case .chat: return .chat
        case .clarify: return .clarify(reason: intent.reason ?? "Could you clarify what you'd like?", alternatives: intent.alternatives)
        case .unsupported: return .unsupported(reason: intent.reason ?? "esh can't perform this here.")
        case .executeCapability, .installProviderThenExecute:
            guard let capability = intent.capability else { return .clarify(reason: "Unclear request.", alternatives: []) }
            // Independent registry check — is there a provider for this capability at all?
            let registered = registry.all.contains { $0.descriptor.capabilities.contains(capability) }
            guard registered else {
                return .unsupported(reason: "esh doesn't have a provider for \(capability.rawValue) yet.")
            }
            let request = Self.buildRequest(capability: capability, intent: intent, message: message, attachments: attachments)

            // Requirement / install-state check (spec §9B, §10).
            if let req = CapabilityRequirementCatalog.requirements[capability],
               !Self.isSatisfied(req, installs: installs, root: root) {
                let installKind: String = { if case .visionModel = req.kind { return "model" }; return "asset" }()
                let requirement = InstallRequirement(
                    capability: capability, componentName: req.componentName, recommendedRepo: req.recommendedRepo,
                    approxSizeMB: req.approxSizeMB, fit: Self.fit(for: req, host: host, root: root), installKind: installKind)
                return .installRequired(request, intent, requirement)
            }
            return .ready(request, intent)
        }
    }

    // MARK: - Validation helpers

    static func isSatisfied(_ req: CapabilityRequirement, installs: [ModelInstall], root: PersistenceRoot) -> Bool {
        switch req.kind {
        case .visionModel:
            return CapabilityModelResolver().resolveModelID(capability: .imageUnderstand, from: installs) != nil
        case .assetFile(let rel):
            let url = root.cachesURL.appendingPathComponent(rel)
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    static func fit(for req: CapabilityRequirement, host: HostMachineProfile?, root: PersistenceRoot) -> ModelFitAssessment? {
        guard let host else { return nil }
        // Rough fit from the component's approx weight size (image fit model; conservative).
        let weightsGB = req.approxSizeMB.map { Double($0) / 1024.0 }
        return ImageModelFitService().assess(
            input: .init(weightsGB: weightsGB, diskRequiredBytes: req.approxSizeMB.map { Int64($0) * 1_048_576 }),
            host: host, root: root)
    }

    // MARK: - Request building (CapabilityIntent → ExecutionRequest)

    static func buildRequest(capability: CapabilityID, intent: CapabilityIntent, message: String, attachments: [EshAttachment]) -> ExecutionRequest {
        var inputs: [CapabilityInput] = []
        // Referenced attachments, in order.
        for ref in intent.inputRefs {
            if let idx = Int(ref.replacingOccurrences(of: "attachment_", with: "")), attachments.indices.contains(idx) {
                inputs.append(.attachment(attachments[idx]))
            }
        }
        // Text input (prompt/question) for capabilities that consume text.
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if textConsuming.contains(capability), !text.isEmpty {
            inputs.append(.text(text, role: "user"))
        }
        var values = intent.arguments
        // Carry any explicit model/latency later; nothing to add here by default.
        _ = values
        return ExecutionRequest(
            capability: capability,
            inputs: inputs,
            output: outputSpec(for: capability),
            constraints: ExecutionConstraints(latency: .interactive),
            options: ExecutionOptions(intent.arguments))
    }

    static let textConsuming: Set<CapabilityID> = [.imageGenerate, .vectorGenerate, .imageUnderstand, .videoUnderstand]

    static func outputSpec(for capability: CapabilityID) -> OutputSpec {
        switch capability {
        case .imageGenerate, .imageUpscale, .imageSegment, .imageEdit: return OutputSpec(modality: .image)
        case .vectorGenerate: return .svg
        case .audioDiarize: return .json
        default: return .text   // understand / ocr / video.understand / transcribe
        }
    }

    static func modality(_ a: EshAttachment) -> ModelModality {
        switch a.kind {
        case .image: return .image
        case .audio: return .audio
        case .video: return .video
        case .document, .other: return .text
        }
    }
}
