import Foundation

public enum ExternalIntegrationID: String, Codable, CaseIterable, Hashable, Sendable {
    case claude
    case codex
}

public enum ExternalIntegrationServerProtocol: String, Codable, Hashable, Sendable {
    case anthropicCompatible = "anthropic"
    case openAICompatible = "openai"
}

public struct ExternalIntegrationDescriptor: Codable, Hashable, Sendable {
    public var id: ExternalIntegrationID
    public var displayName: String
    public var executableName: String
    public var installCommand: String
    public var docsURL: String
    public var serverProtocol: ExternalIntegrationServerProtocol

    public init(
        id: ExternalIntegrationID,
        displayName: String,
        executableName: String,
        installCommand: String,
        docsURL: String,
        serverProtocol: ExternalIntegrationServerProtocol
    ) {
        self.id = id
        self.displayName = displayName
        self.executableName = executableName
        self.installCommand = installCommand
        self.docsURL = docsURL
        self.serverProtocol = serverProtocol
    }
}

public struct ExternalIntegrationLaunchPlan: Hashable, Sendable {
    public var integrationID: ExternalIntegrationID
    public var executableName: String
    public var serverProtocol: ExternalIntegrationServerProtocol
    public var arguments: [String]
    public var environment: [String: String]
    public var configurationFileContents: String?

    public init(
        integrationID: ExternalIntegrationID,
        executableName: String,
        serverProtocol: ExternalIntegrationServerProtocol,
        arguments: [String],
        environment: [String: String],
        configurationFileContents: String? = nil
    ) {
        self.integrationID = integrationID
        self.executableName = executableName
        self.serverProtocol = serverProtocol
        self.arguments = arguments
        self.environment = environment
        self.configurationFileContents = configurationFileContents
    }
}
