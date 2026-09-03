import Foundation

// esh 2.1 UCMR, Stage 0 — typed result + typed streaming events. Additive to the text-only
// `ExternalInferenceResponse` and the existing `EshStreamEvent` (which stays for the 2.0 chat path).

/// A normalized, modality-generic streaming event for a capability execution. Extends the shape of
/// `EshStreamEvent` with lifecycle/artifact events; media deltas are additive as providers support them.
public enum CapabilityEvent: Sendable {
    case status(String)                 // human-facing status line ("loading model", "vectorizing")
    case progress(Double)               // 0.0...1.0 where meaningful
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

    public init(capability: CapabilityID,
                text: String? = nil,
                outputs: [Artifact] = [],
                metrics: Metrics? = nil,
                usage: EshUsage? = nil,
                executionPlanID: UUID? = nil,
                schemaVersion: String = ExecutionResult.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.capability = capability
        self.text = text
        self.outputs = outputs
        self.metrics = metrics
        self.usage = usage
        self.executionPlanID = executionPlanID
    }
}
