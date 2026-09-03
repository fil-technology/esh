import Foundation

// esh 2.1 — Capability routing benchmark (spec 86eyucfbu §1/§2/§6/§7). A carefully-labeled, adversarial,
// multilingual (EN/RU/HE) dataset + a harness with SEPARATED metrics and an ASYMMETRIC conservative score:
// a wrong execution is far worse than an unnecessary clarification, which is worse than a missed automation.
// Works for any router (Tier-0 deterministic, a Tier-1 semantic router, or the hybrid) via `runRouter`.

public struct RoutingCase: Sendable, Equatable {
    public var message: String
    public var inputs: [ModelModality]
    public var expectedAction: RouterAction
    public var expectedCapability: CapabilityID?
    public var expectedArgs: [String: JSONValue]?
    public var expectedInputRefs: [String]?
    public var category: String
    public var language: String
    public init(_ message: String, inputs: [ModelModality] = [], expect action: RouterAction,
                capability: CapabilityID? = nil, args: [String: JSONValue]? = nil, refs: [String]? = nil,
                category: String, language: String = "en") {
        self.message = message; self.inputs = inputs; self.expectedAction = action
        self.expectedCapability = capability; self.expectedArgs = args; self.expectedInputRefs = refs
        self.category = category; self.language = language
    }
}

public struct RoutingMetrics: Sendable {
    public var total = 0
    public var actionCorrect = 0
    public var capabilityCases = 0, capabilityCorrect = 0
    public var argCases = 0, argCorrect = 0
    public var refCases = 0, refCorrect = 0
    public var falseExecutions = 0          // executed when it shouldn't have, or wrong capability
    public var missedCapability = 0         // expected execute, predicted chat/clarify/unsupported
    public var unnecessaryClarification = 0 // predicted clarify when expected wasn't clarify
    public var clarifyExpected = 0, clarifyPredicted = 0, clarifyCorrect = 0
    public var chatExpected = 0, chatCorrect = 0
    public var unsupportedExpected = 0, unsupportedCorrect = 0
    public var perLanguage: [String: (total: Int, actionCorrect: Int)] = [:]
    public var failures: [String] = []

    public var capabilitySelectionAccuracy: Double { capabilityCases == 0 ? 1 : Double(capabilityCorrect) / Double(capabilityCases) }
    public var argumentAccuracy: Double { argCases == 0 ? 1 : Double(argCorrect) / Double(argCases) }
    public var inputRefAccuracy: Double { refCases == 0 ? 1 : Double(refCorrect) / Double(refCases) }
    public var falseExecutionRate: Double { total == 0 ? 0 : Double(falseExecutions) / Double(total) }
    public var chatAccuracy: Double { chatExpected == 0 ? 1 : Double(chatCorrect) / Double(chatExpected) }
    public var unsupportedAccuracy: Double { unsupportedExpected == 0 ? 1 : Double(unsupportedCorrect) / Double(unsupportedExpected) }
    public var clarifyRecall: Double { clarifyExpected == 0 ? 1 : Double(clarifyCorrect) / Double(clarifyExpected) }
    public var clarifyPrecision: Double { clarifyPredicted == 0 ? 1 : Double(clarifyCorrect) / Double(clarifyPredicted) }
    public var actionAccuracy: Double { total == 0 ? 0 : Double(actionCorrect) / Double(total) }
    public func languageActionAccuracy(_ lang: String) -> Double {
        guard let e = perLanguage[lang], e.total > 0 else { return 1 }
        return Double(e.actionCorrect) / Double(e.total)
    }

    // Conservative score (spec §2). Documented, non-arbitrary weights encoding
    // "wrong execution >>> unnecessary clarification > missed automation".
    public static let wCorrect = 1.0
    public static let wFalseExecution = -6.0     // strongest penalty — running the wrong transformation is worst
    public static let wUnnecessaryClarify = -1.0 // mild — a needless question is cheap
    public static let wMissedCapability = -2.0   // moderate — we failed to automate, but did no harm
    /// Sum of weighted outcomes divided by total (so it's comparable across dataset sizes).
    public var conservativeScore: Double {
        guard total > 0 else { return 0 }
        let correct = actionCorrect
        let raw = Double(correct) * Self.wCorrect
            + Double(falseExecutions) * Self.wFalseExecution
            + Double(unnecessaryClarification) * Self.wUnnecessaryClarify
            + Double(missedCapability) * Self.wMissedCapability
        return raw / Double(total)
    }
}

/// Wrapper for the per-case detail endpoint (POST /v1/route/benchmark/detail).
public struct RouterBenchmarkDetail: Codable, Sendable {
    public var mode: String
    public var cases: [RoutingBenchmark.CaseResult]
    public init(mode: String, cases: [RoutingBenchmark.CaseResult]) { self.mode = mode; self.cases = cases }
}

public enum RoutingBenchmark {
    public static let datasetVersion = 2

    /// Score one prediction against a case, accumulating into `m`.
    static func score(_ m: inout RoutingMetrics, _ c: RoutingCase, _ intent: CapabilityIntent) {
        m.total += 1
        var langEntry = m.perLanguage[c.language] ?? (0, 0); langEntry.total += 1
        let predicted = intent.action
        let predictedExecutes = (predicted == .executeCapability || predicted == .installProviderThenExecute)
        let expectedExecutes = (c.expectedAction == .executeCapability || c.expectedAction == .installProviderThenExecute)
        let actionOK = (predicted == c.expectedAction) || (expectedExecutes && predictedExecutes)
        if actionOK { m.actionCorrect += 1; langEntry.actionCorrect += 1 }
        m.perLanguage[c.language] = langEntry

        if expectedExecutes {
            m.capabilityCases += 1
            let capOK = predictedExecutes && intent.capability == c.expectedCapability
            if capOK { m.capabilityCorrect += 1 } else {
                m.failures.append("[\(c.language)/\(c.category)] \"\(c.message)\" → \(predicted)/\(intent.capability?.rawValue ?? "-") (want \(c.expectedCapability?.rawValue ?? "-"))")
            }
            if !predictedExecutes { m.missedCapability += 1 }
            if predictedExecutes && intent.capability != c.expectedCapability { m.falseExecutions += 1 }
            if let want = c.expectedArgs { m.argCases += 1; if capOK && argsMatch(intent.arguments, want) { m.argCorrect += 1 } }
            if let want = c.expectedInputRefs { m.refCases += 1; if capOK && intent.inputRefs == want { m.refCorrect += 1 } }
        } else {
            if predictedExecutes { m.falseExecutions += 1
                m.failures.append("FALSE-EXEC [\(c.language)/\(c.category)] \"\(c.message)\" → \(intent.capability?.rawValue ?? "-") (want \(c.expectedAction))") }
        }
        if predicted == .clarify && c.expectedAction != .clarify { m.unnecessaryClarification += 1 }
        if c.expectedAction == .clarify { m.clarifyExpected += 1; if predicted == .clarify { m.clarifyCorrect += 1 } }
        if predicted == .clarify { m.clarifyPredicted += 1 }
        if c.expectedAction == .chat { m.chatExpected += 1; if predicted == .chat { m.chatCorrect += 1 } }
        if c.expectedAction == .unsupported { m.unsupportedExpected += 1; if predicted == .unsupported { m.unsupportedCorrect += 1 } }
    }

    static func argsMatch(_ got: [String: JSONValue], _ want: [String: JSONValue]) -> Bool {
        for (k, v) in want { if got[k] != v { return false } }
        return true
    }

    /// Deterministic Tier-0 run (sync).
    public static func run(_ cases: [RoutingCase], router: DeterministicIntentRouter = .init()) -> RoutingMetrics {
        var m = RoutingMetrics()
        for c in cases { score(&m, c, router.route(message: c.message, inputModalities: c.inputs)) }
        return m
    }

    /// Generic run for ANY router (Tier-1 semantic, or a hybrid closure). Async.
    public static func runRouter(_ cases: [RoutingCase],
                                 route: @Sendable (_ message: String, _ inputs: [ModelModality]) async -> CapabilityIntent) async -> RoutingMetrics {
        var m = RoutingMetrics()
        for c in cases { let intent = await route(c.message, c.inputs); score(&m, c, intent) }
        return m
    }

    /// Per-case outcome for failure analysis (which cases a router mis-routes, and how). Additive — no
    /// change to scoring; `isFalseExecution` uses the SAME rule as `score`.
    public struct CaseResult: Codable, Sendable {
        public var message, language, category, expectedAction: String
        public var expectedCapability: String?
        public var predictedAction: String
        public var predictedCapability: String?
        public var predictedClarifyKind: String?   // ambiguous | unresolved (Tier-0 clarify subtype)
        public var provenanceTier: String?          // tier0-deterministic | tier1-semantic (who decided)
        public var isFalseExecution: Bool
        public var isMissed: Bool
        public var isUnnecessaryClarify: Bool
    }

    /// Run a router and return per-case detail (for classifying false executions). Async.
    public static func runRouterDetail(_ cases: [RoutingCase],
                                       route: @Sendable (_ message: String, _ inputs: [ModelModality]) async -> CapabilityIntent) async -> [CaseResult] {
        var out: [CaseResult] = []
        for c in cases {
            let intent = await route(c.message, c.inputs)
            let predExec = (intent.action == .executeCapability || intent.action == .installProviderThenExecute)
            let expExec = (c.expectedAction == .executeCapability || c.expectedAction == .installProviderThenExecute)
            let falseExec = (!expExec && predExec) || (expExec && predExec && intent.capability != c.expectedCapability)
            out.append(CaseResult(
                message: c.message, language: c.language, category: c.category,
                expectedAction: c.expectedAction.rawValue, expectedCapability: c.expectedCapability?.rawValue,
                predictedAction: intent.action.rawValue, predictedCapability: intent.capability?.rawValue,
                predictedClarifyKind: intent.clarifyKind?.rawValue, provenanceTier: intent.provenance.tier,
                isFalseExecution: falseExec,
                isMissed: expExec && !predExec,
                isUnnecessaryClarify: intent.action == .clarify && c.expectedAction != .clarify))
        }
        return out
    }

    /// The original small EN seed (kept for existing tests). The full multilingual dataset is `RoutingDataset.all`.
    public static let seed: [RoutingCase] = RoutingDataset.englishCore
}
