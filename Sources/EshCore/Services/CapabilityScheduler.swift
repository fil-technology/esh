import Foundation

// esh 2.1 — Stage 4.2b: performance-aware capability selection. A SMALL, explicit rule (not a giant score)
// that turns CapabilityPerformanceEvidence into a decision: which model, and — for interactive requests —
// which config, so Auto avoids "fits in memory but impractically slow". Pure + deterministic; wired into
// CapabilityExecutionService in 4.2c. See 2_1_STAGE4_2_SCHEDULER_V2_DESIGN.md.

public struct CapabilityScheduleDecision: Sendable, Equatable {
    public var modelID: String?
    public var optionOverrides: [String: JSONValue]
    public var rationale: [String]
    public var evidenceBacked: Bool
    public init(modelID: String? = nil, optionOverrides: [String: JSONValue] = [:], rationale: [String] = [], evidenceBacked: Bool = false) {
        self.modelID = modelID
        self.optionOverrides = optionOverrides
        self.rationale = rationale
        self.evidenceBacked = evidenceBacked
    }
    public static let none = CapabilityScheduleDecision()
}

public struct CapabilityScheduler: Sendable {
    private let index: CapabilityEvidenceIndex
    /// The "useful performance" line for interactive requests, in seconds per unit (image, etc.).
    private let interactiveBudgetSeconds: Double
    /// Reliability floor a candidate must meet to be preferred on speed (0…1).
    private let reliabilityFloor: Double

    public init(index: CapabilityEvidenceIndex, interactiveBudgetSeconds: Double = 60, reliabilityFloor: Double = 0.5) {
        self.index = index
        self.interactiveBudgetSeconds = interactiveBudgetSeconds
        self.reliabilityFloor = reliabilityFloor
    }

    /// Decide model + (interactive) config for a capability request.
    /// - currentModel: an explicitly-requested model (nil → free to choose).
    /// - candidateModelIDs: installed models capable of this capability (may be empty / single).
    /// - requestedConfig: cost-driving knobs already set on the request (e.g. width/height).
    public func decide(capability: CapabilityID, currentModel: String?, candidateModelIDs: [String],
                       requestedConfig: [String: JSONValue], latency: CapabilityRequest.Latency?) -> CapabilityScheduleDecision {
        var decision = CapabilityScheduleDecision()
        let interactive = (latency ?? .interactive) == .interactive

        // 1) Model choice — only when the caller didn't pin one AND there is a real choice with evidence.
        if currentModel == nil, candidateModelIDs.count > 1 {
            let scored = candidateModelIDs.compactMap { id -> (String, CapabilityPerformanceEvidence)? in
                let ev = index.all(capability: capability).filter { $0.modelID == id && !$0.experimental && !$0.measuredUnderMemoryPressure }
                let pick = interactive
                    ? ev.min { ($0.secondsPerUnit ?? .greatestFiniteMagnitude) < ($1.secondsPerUnit ?? .greatestFiniteMagnitude) }
                    : ev.max { ($0.reliability ?? 0) < ($1.reliability ?? 0) }
                return pick.map { (id, $0) }
            }
            if !scored.isEmpty {
                let best = interactive
                    ? scored.min { ($0.1.secondsPerUnit ?? .greatestFiniteMagnitude) < ($1.1.secondsPerUnit ?? .greatestFiniteMagnitude) }!
                    : scored.max { ($0.1.reliability ?? 0) < ($1.1.reliability ?? 0) }!
                decision.modelID = best.0
                decision.evidenceBacked = true
                if let s = best.1.secondsPerUnit {
                    decision.rationale.append(String(format: "chose %@: measured ~%.0f s/%@ on this Mac (%@)",
                                                     best.0, s, best.1.unit, interactive ? "interactive" : "batch"))
                }
            }
        }

        // 2) Interactive config (resolution) — only for image.generate, when no explicit size was given and
        //    the evidence shows the default is over budget while a smaller config is within it.
        if capability == .imageGenerate, interactive,
           requestedConfig["width"] == nil, requestedConfig["height"] == nil {
            let model = decision.modelID ?? currentModel
            let pool = index.all(capability: capability).filter {
                (model == nil || $0.modelID == model) && !$0.experimental && !$0.measuredUnderMemoryPressure && $0.secondsPerUnit != nil
            }
            let overBudget = pool.contains { ($0.secondsPerUnit ?? 0) > interactiveBudgetSeconds }
            let within = pool.filter { ($0.secondsPerUnit ?? .greatestFiniteMagnitude) <= interactiveBudgetSeconds }
            if overBudget, let fastest = within.min(by: { ($0.secondsPerUnit ?? 0) < ($1.secondsPerUnit ?? 0) }),
               case let .int(w)? = fastest.config["width"], case let .int(h)? = fastest.config["height"] {
                decision.optionOverrides["width"] = .int(w)
                decision.optionOverrides["height"] = .int(h)
                decision.evidenceBacked = true
                let slow = pool.map { $0.secondsPerUnit ?? 0 }.max() ?? 0
                decision.rationale.append(String(format: "interactive: default resolution measured ~%.0f s (> %.0f s budget); using %dx%d (~%.0f s). Ask for a larger size or batch mode for full resolution.",
                                                 slow, interactiveBudgetSeconds, w, h, fastest.secondsPerUnit ?? 0))
            }
        }
        return decision
    }
}
