import Foundation

public struct RunState: Codable, Hashable, Sendable {
    public let runID: String
    public let workspaceRootPath: String
    public var status: String
    public var discoveredFiles: [String]
    public var discoveredSymbols: [String]
    public var hypotheses: [String]
    public var findings: [String]
    public var decisions: [String]
    public var pendingTasks: [String]
    public var completedTasks: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        runID: String,
        workspaceRootPath: String,
        status: String = "active",
        discoveredFiles: [String] = [],
        discoveredSymbols: [String] = [],
        hypotheses: [String] = [],
        findings: [String] = [],
        decisions: [String] = [],
        pendingTasks: [String] = [],
        completedTasks: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.runID = runID
        self.workspaceRootPath = workspaceRootPath
        self.status = status
        self.discoveredFiles = discoveredFiles
        self.discoveredSymbols = discoveredSymbols
        self.hypotheses = hypotheses
        self.findings = findings
        self.decisions = decisions
        self.pendingTasks = pendingTasks
        self.completedTasks = completedTasks
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct RunEvent: Codable, Hashable, Sendable {
    public let runID: String
    public let timestamp: Date
    public let kind: String
    public let detail: String
    public let attributes: [String: String]?

    public init(
        runID: String,
        timestamp: Date = Date(),
        kind: String,
        detail: String,
        attributes: [String: String]? = nil
    ) {
        self.runID = runID
        self.timestamp = timestamp
        self.kind = kind
        self.detail = detail
        self.attributes = attributes
    }
}

public struct RunTrace: Codable, Hashable, Sendable {
    public let state: RunState
    public let events: [RunEvent]

    public init(state: RunState, events: [RunEvent]) {
        self.state = state
        self.events = events
    }
}

public struct RunTaskTransition: Codable, Hashable, Sendable {
    public let timestamp: Date
    public let phase: String
    public let detail: String

    public init(timestamp: Date = Date(), phase: String, detail: String) {
        self.timestamp = timestamp
        self.phase = phase
        self.detail = detail
    }
}
