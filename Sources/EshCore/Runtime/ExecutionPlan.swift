import Foundation

// esh 2.1 UCMR, Stage 0 — a first-class, capability-typed ExecutionPlan. This promotes the implicit
// SchedulerDecision + ExecutionProfile pair into an explicit plan that can also express multi-provider
// pipelines. Additive: the existing SchedulerDecision/ExecutionProfile types remain and are embedded
// per step. See docs/UCMR_ARCHITECTURE.md §6.

/// One stage of an execution. A single-provider call is a 1-step plan; a multimodal pipeline
/// (e.g. video→keyframes→VLM + audio→STT → reasoning) is an N-step plan.
public struct ExecutionStep: Codable, Sendable, Equatable {
    public var providerID: String
    public var modelID: String?
    public var backend: RuntimeKind
    /// Reuse the existing per-model optimization profile where applicable (LLM steps).
    public var profile: ExecutionProfile?
    /// Index of an earlier step whose output this step consumes (nil = consumes the request inputs).
    public var consumesOutputOf: Int?

    public init(providerID: String, modelID: String? = nil, backend: RuntimeKind,
                profile: ExecutionProfile? = nil, consumesOutputOf: Int? = nil) {
        self.providerID = providerID
        self.modelID = modelID
        self.backend = backend
        self.profile = profile
        self.consumesOutputOf = consumesOutputOf
    }
}

public struct ExecutionPlan: Codable, Sendable, Equatable {
    public var id: UUID
    public var capability: CapabilityID
    public var inputModalities: [ModelModality]
    public var outputModality: ModelModality
    public var steps: [ExecutionStep]
    /// Truthful "Why this execution plan?" record (per spec §11).
    public var rationale: [String]
    public var evidenceBacked: Bool
    public var estimatedPeakMemoryGB: Double?
    public var privilegeLevel: PrivilegeLevel

    public init(id: UUID = UUID(),
                capability: CapabilityID,
                inputModalities: [ModelModality],
                outputModality: ModelModality,
                steps: [ExecutionStep],
                rationale: [String] = [],
                evidenceBacked: Bool = false,
                estimatedPeakMemoryGB: Double? = nil,
                privilegeLevel: PrivilegeLevel = .artifactOnly) {
        self.id = id
        self.capability = capability
        self.inputModalities = inputModalities
        self.outputModality = outputModality
        self.steps = steps
        self.rationale = rationale
        self.evidenceBacked = evidenceBacked
        self.estimatedPeakMemoryGB = estimatedPeakMemoryGB
        self.privilegeLevel = privilegeLevel
    }

    public var isPipeline: Bool { steps.count > 1 }
    public var singleStep: ExecutionStep? { steps.count == 1 ? steps[0] : nil }

    /// Build a single-provider plan for a request executed by one chosen provider/model.
    public static func single(capability: CapabilityID,
                              inputModalities: [ModelModality],
                              outputModality: ModelModality,
                              providerID: String,
                              modelID: String? = nil,
                              backend: RuntimeKind,
                              rationale: [String] = [],
                              evidenceBacked: Bool = false,
                              estimatedPeakMemoryGB: Double? = nil,
                              privilegeLevel: PrivilegeLevel = .artifactOnly) -> ExecutionPlan {
        ExecutionPlan(
            capability: capability,
            inputModalities: inputModalities,
            outputModality: outputModality,
            steps: [ExecutionStep(providerID: providerID, modelID: modelID, backend: backend)],
            rationale: rationale,
            evidenceBacked: evidenceBacked,
            estimatedPeakMemoryGB: estimatedPeakMemoryGB,
            privilegeLevel: privilegeLevel)
    }
}
