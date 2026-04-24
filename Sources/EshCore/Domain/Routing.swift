import Foundation

public enum RoutingMode: String, Codable, CaseIterable, Sendable {
    case disabled
    case single
    case sequential
    case parallel
}

public enum ModelRole: String, Codable, CaseIterable, Sendable {
    case router
    case main
    case coding
    case embedding
    case fallback
}

public struct RoutingConfiguration: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var mode: RoutingMode
    public var routerModel: String?
    public var mainModel: String?
    public var codingModel: String?
    public var embeddingModel: String?
    public var fallbackModel: String?
    public var maxRouterTokens: Int
    public var routerTemperature: Double
    public var mainTemperature: Double
    public var minimumConfidence: Double

    public init(
        enabled: Bool = false,
        mode: RoutingMode = .disabled,
        routerModel: String? = nil,
        mainModel: String? = nil,
        codingModel: String? = nil,
        embeddingModel: String? = nil,
        fallbackModel: String? = nil,
        maxRouterTokens: Int = 512,
        routerTemperature: Double = 0.0,
        mainTemperature: Double = 0.3,
        minimumConfidence: Double = 0.5
    ) {
        self.enabled = enabled
        self.mode = mode
        self.routerModel = routerModel
        self.mainModel = mainModel
        self.codingModel = codingModel
        self.embeddingModel = embeddingModel
        self.fallbackModel = fallbackModel
        self.maxRouterTokens = maxRouterTokens
        self.routerTemperature = routerTemperature
        self.mainTemperature = mainTemperature
        self.minimumConfidence = minimumConfidence
    }

    public func modelID(for role: ModelRole) -> String? {
        switch role {
        case .router:
            routerModel
        case .main:
            mainModel
        case .coding:
            codingModel ?? mainModel
        case .embedding:
            embeddingModel
        case .fallback:
            fallbackModel ?? mainModel
        }
    }
}

public enum RoutingAction: String, Codable, CaseIterable, Sendable {
    case answerDirectly = "answer_directly"
    case delegateToModel = "delegate_to_model"
    case callTool = "call_tool"
    case askClarification = "ask_clarification"
    case refuse
}

public struct RoutingToolCall: Codable, Hashable, Sendable {
    public var name: String
    public var arguments: [String: String]

    public init(name: String, arguments: [String: String] = [:]) {
        self.name = name
        self.arguments = arguments
    }
}

public struct RoutingDecision: Codable, Hashable, Sendable {
    public var action: RoutingAction
    public var targetModelRole: ModelRole
    public var toolCall: RoutingToolCall?
    public var reason: String
    public var confidence: Double
    public var requiresLongContext: Bool
    public var requiresRepoAccess: Bool
    public var requiresInternet: Bool
    public var requiresFilesystem: Bool
    public var answer: String?
    public var clarificationQuestion: String?

    public init(
        action: RoutingAction,
        targetModelRole: ModelRole = .main,
        toolCall: RoutingToolCall? = nil,
        reason: String = "",
        confidence: Double = 1.0,
        requiresLongContext: Bool = false,
        requiresRepoAccess: Bool = false,
        requiresInternet: Bool = false,
        requiresFilesystem: Bool = false,
        answer: String? = nil,
        clarificationQuestion: String? = nil
    ) {
        self.action = action
        self.targetModelRole = targetModelRole
        self.toolCall = toolCall
        self.reason = reason
        self.confidence = confidence
        self.requiresLongContext = requiresLongContext
        self.requiresRepoAccess = requiresRepoAccess
        self.requiresInternet = requiresInternet
        self.requiresFilesystem = requiresFilesystem
        self.answer = answer
        self.clarificationQuestion = clarificationQuestion
    }
}

public struct RoutingTrace: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var mode: RoutingMode
    public var routerModel: String?
    public var selectedModel: String?
    public var decision: RoutingDecision?
    public var fallbackReason: String?
    public var routingLatencyMilliseconds: Int?

    public init(
        enabled: Bool,
        mode: RoutingMode,
        routerModel: String? = nil,
        selectedModel: String? = nil,
        decision: RoutingDecision? = nil,
        fallbackReason: String? = nil,
        routingLatencyMilliseconds: Int? = nil
    ) {
        self.enabled = enabled
        self.mode = mode
        self.routerModel = routerModel
        self.selectedModel = selectedModel
        self.decision = decision
        self.fallbackReason = fallbackReason
        self.routingLatencyMilliseconds = routingLatencyMilliseconds
    }
}
