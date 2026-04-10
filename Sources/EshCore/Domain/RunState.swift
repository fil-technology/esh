import Foundation

public struct RunState: Codable, Hashable, Sendable {
    public let runID: String
    public let workspaceRootPath: String
    public var discoveredFiles: [String]
    public var discoveredSymbols: [String]
    public var decisions: [String]
    public var pendingTasks: [String]
    public var completedTasks: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        runID: String,
        workspaceRootPath: String,
        discoveredFiles: [String] = [],
        discoveredSymbols: [String] = [],
        decisions: [String] = [],
        pendingTasks: [String] = [],
        completedTasks: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.runID = runID
        self.workspaceRootPath = workspaceRootPath
        self.discoveredFiles = discoveredFiles
        self.discoveredSymbols = discoveredSymbols
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

    public init(runID: String, timestamp: Date = Date(), kind: String, detail: String) {
        self.runID = runID
        self.timestamp = timestamp
        self.kind = kind
        self.detail = detail
    }
}
