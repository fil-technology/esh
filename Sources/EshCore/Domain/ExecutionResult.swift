import Foundation

// esh 2.1 UCMR, Stage 0 — typed result + typed streaming events. Additive to the text-only
// `ExternalInferenceResponse` and the existing `EshStreamEvent` (which stays for the 2.0 chat path).

/// A normalized, modality-generic streaming event for a capability execution. Extends the shape of
/// `EshStreamEvent` with lifecycle/artifact events; media deltas are additive as providers support them.
public enum CapabilityEvent: Sendable {
    case status(String)                 // human-facing status line ("loading model", "vectorizing")
    case progress(Double)               // 0.0...1.0 where meaningful
    case planResolved(ExecutionPlan)    // the composed pipeline this execution is running (single or N-step)
    case textDelta(String)
    case reasoningDelta(String)
    case artifactProduced(Artifact)     // a typed output is ready (referenced by id)
    case previewReady(url: String)      // a preview surface is available
    case usage(EshUsage)
    case done(finishReason: String?)
    case failed(message: String)
}

/// The typed result of a capability execution. `text` is retained for text-producing capabilities;
/// `outputs` carries typed artifacts (image/svg/audio/embedding/…). Both may be present.
public struct ExecutionResult: Codable, Sendable {
    public static let currentSchemaVersion = "esh.execute.response.v1"
    public var schemaVersion: String
    public var capability: CapabilityID
    public var text: String?
    public var outputs: [Artifact]
    public var metrics: Metrics?
    public var usage: EshUsage?
    public var executionPlanID: UUID?
    /// The composed ExecutionPlan (single-provider or multi-provider pipeline) that produced this result,
    /// for the Execution Inspector and "Why this execution plan?". Additive; nil for legacy paths.
    public var plan: ExecutionPlan?
    /// A preview surface URL a provider signalled via `.previewReady` (e.g. a managed project's entry URL
    /// or a Tier-C loopback dev server). Additive; nil when there is no distinct preview surface.
    public var previewURL: String?

    public init(capability: CapabilityID,
                text: String? = nil,
                outputs: [Artifact] = [],
                metrics: Metrics? = nil,
                usage: EshUsage? = nil,
                executionPlanID: UUID? = nil,
                plan: ExecutionPlan? = nil,
                previewURL: String? = nil,
                schemaVersion: String = ExecutionResult.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.capability = capability
        self.text = text
        self.outputs = outputs
        self.metrics = metrics
        self.usage = usage
        self.executionPlanID = executionPlanID ?? plan?.id
        self.plan = plan
        self.previewURL = previewURL
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, capability, text, outputs, metrics, usage, executionPlanID, plan, previewURL
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(String.self, forKey: .schemaVersion) ?? ExecutionResult.currentSchemaVersion
        self.capability = try c.decode(CapabilityID.self, forKey: .capability)
        self.text = try c.decodeIfPresent(String.self, forKey: .text)
        self.outputs = try c.decodeIfPresent([Artifact].self, forKey: .outputs) ?? []
        self.metrics = try c.decodeIfPresent(Metrics.self, forKey: .metrics)
        self.usage = try c.decodeIfPresent(EshUsage.self, forKey: .usage)
        self.plan = try c.decodeIfPresent(ExecutionPlan.self, forKey: .plan)
        self.executionPlanID = try c.decodeIfPresent(UUID.self, forKey: .executionPlanID) ?? plan?.id
        self.previewURL = try c.decodeIfPresent(String.self, forKey: .previewURL)
    }
}
