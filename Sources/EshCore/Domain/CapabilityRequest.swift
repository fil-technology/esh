import Foundation

/// A capability-oriented request: "fulfill capability Y under constraints", instead of naming an
/// exact model/backend/quant. The Adaptive Scheduler turns this into a concrete plan.
public struct CapabilityRequest: Codable, Sendable, Equatable {
    public enum Goal: String, Codable, Sendable, CaseIterable {
        case general, coding, reasoning, structured
        public init?(cliValue: String) {
            switch cliValue.lowercased() {
            case "general", "chat": self = .general
            case "coding", "code": self = .coding
            case "reasoning", "reason": self = .reasoning
            case "structured", "tools", "json": self = .structured
            default: return nil
            }
        }
    }
    public enum Quality: String, Codable, Sendable, CaseIterable {
        case high, balanced, fast
        public init?(cliValue: String) { self.init(rawValue: cliValue.lowercased()) }
    }
    public enum Latency: String, Codable, Sendable, CaseIterable {
        case interactive, batch
        public init?(cliValue: String) { self.init(rawValue: cliValue.lowercased()) }
    }

    public var goal: Goal
    public var quality: Quality
    public var latency: Latency
    public var expectedContextTokens: Int?
    public var toolCallingRequired: Bool
    public var visionRequired: Bool
    public var localOnly: Bool

    public init(
        goal: Goal = .general,
        quality: Quality = .balanced,
        latency: Latency = .interactive,
        expectedContextTokens: Int? = nil,
        toolCallingRequired: Bool = false,
        visionRequired: Bool = false,
        localOnly: Bool = true
    ) {
        self.goal = goal
        self.quality = quality
        self.latency = latency
        self.expectedContextTokens = expectedContextTokens
        self.toolCallingRequired = toolCallingRequired
        self.visionRequired = visionRequired
        self.localOnly = localOnly
    }
}

/// The scheduler's evidence-backed decision, with recorded rationale (WHY it chose what it did).
public struct SchedulerDecision: Codable, Sendable, Equatable {
    public var selectedModelID: String?
    public var backend: BackendKind?
    public var performanceMode: PerformanceMode
    public var executionProfile: ExecutionProfile?
    public var fitClass: String?
    public var estimatedPeakMemoryGB: Double?
    /// True when the scheduler recommends Apple Intelligence (zero-download) because no installed
    /// model fit — a recommendation only; it never silently replaces an explicit model choice.
    public var appleIntelligenceSuggested: Bool
    public var evidenceBacked: Bool
    public var candidatesConsidered: Int
    public var rationale: [String]
    public var warnings: [String]

    public init(
        selectedModelID: String? = nil,
        backend: BackendKind? = nil,
        performanceMode: PerformanceMode = .balanced,
        executionProfile: ExecutionProfile? = nil,
        fitClass: String? = nil,
        estimatedPeakMemoryGB: Double? = nil,
        appleIntelligenceSuggested: Bool = false,
        evidenceBacked: Bool = false,
        candidatesConsidered: Int = 0,
        rationale: [String] = [],
        warnings: [String] = []
    ) {
        self.selectedModelID = selectedModelID
        self.backend = backend
        self.performanceMode = performanceMode
        self.executionProfile = executionProfile
        self.fitClass = fitClass
        self.estimatedPeakMemoryGB = estimatedPeakMemoryGB
        self.appleIntelligenceSuggested = appleIntelligenceSuggested
        self.evidenceBacked = evidenceBacked
        self.candidatesConsidered = candidatesConsidered
        self.rationale = rationale
        self.warnings = warnings
    }
}
