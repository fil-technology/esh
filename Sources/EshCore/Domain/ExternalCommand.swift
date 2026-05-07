import Foundation

public struct ExternalCommandDescriptor: Codable, Hashable, Sendable {
    public var name: String
    public var inputSchema: String
    public var outputSchema: String
    public var transport: String

    public init(
        name: String,
        inputSchema: String,
        outputSchema: String,
        transport: String
    ) {
        self.name = name
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.transport = transport
    }
}

public struct ExternalBackendCapability: Codable, Hashable, Sendable {
    public var backend: BackendKind
    public var supportsDirectInference: Bool
    public var supportsCacheBuild: Bool
    public var supportsCacheLoad: Bool
    public var supportedFeatures: [BackendRuntimeFeature]
    public var unavailableFeatures: [UnavailableBackendFeature]

    public init(
        backend: BackendKind,
        supportsDirectInference: Bool,
        supportsCacheBuild: Bool,
        supportsCacheLoad: Bool,
        supportedFeatures: [BackendRuntimeFeature] = [],
        unavailableFeatures: [UnavailableBackendFeature] = []
    ) {
        self.backend = backend
        self.supportsDirectInference = supportsDirectInference
        self.supportsCacheBuild = supportsCacheBuild
        self.supportsCacheLoad = supportsCacheLoad
        self.supportedFeatures = supportedFeatures
        self.unavailableFeatures = unavailableFeatures
    }

    enum CodingKeys: String, CodingKey {
        case backend
        case supportsDirectInference
        case supportsCacheBuild
        case supportsCacheLoad
        case supportedFeatures
        case unavailableFeatures
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.backend = try container.decode(BackendKind.self, forKey: .backend)
        self.supportsDirectInference = try container.decode(Bool.self, forKey: .supportsDirectInference)
        self.supportsCacheBuild = try container.decode(Bool.self, forKey: .supportsCacheBuild)
        self.supportsCacheLoad = try container.decode(Bool.self, forKey: .supportsCacheLoad)
        self.supportedFeatures = try container.decodeIfPresent([BackendRuntimeFeature].self, forKey: .supportedFeatures) ?? []
        self.unavailableFeatures = try container.decodeIfPresent([UnavailableBackendFeature].self, forKey: .unavailableFeatures) ?? []
    }
}

public struct ExternalInstalledModelCapability: Codable, Hashable, Sendable {
    public var id: String
    public var displayName: String
    public var backend: BackendKind
    public var source: String
    public var variant: String?
    public var runtimeVersion: String?
    public var supportsDirectInference: Bool
    public var supportsCacheBuild: Bool
    public var supportsCacheLoad: Bool
    public var supportedFeatures: [BackendRuntimeFeature]
    public var unavailableFeatures: [UnavailableBackendFeature]

    public init(
        id: String,
        displayName: String,
        backend: BackendKind,
        source: String,
        variant: String?,
        runtimeVersion: String?,
        supportsDirectInference: Bool,
        supportsCacheBuild: Bool,
        supportsCacheLoad: Bool,
        supportedFeatures: [BackendRuntimeFeature] = [],
        unavailableFeatures: [UnavailableBackendFeature] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.backend = backend
        self.source = source
        self.variant = variant
        self.runtimeVersion = runtimeVersion
        self.supportsDirectInference = supportsDirectInference
        self.supportsCacheBuild = supportsCacheBuild
        self.supportsCacheLoad = supportsCacheLoad
        self.supportedFeatures = supportedFeatures
        self.unavailableFeatures = unavailableFeatures
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case backend
        case source
        case variant
        case runtimeVersion
        case supportsDirectInference
        case supportsCacheBuild
        case supportsCacheLoad
        case supportedFeatures
        case unavailableFeatures
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.backend = try container.decode(BackendKind.self, forKey: .backend)
        self.source = try container.decode(String.self, forKey: .source)
        self.variant = try container.decodeIfPresent(String.self, forKey: .variant)
        self.runtimeVersion = try container.decodeIfPresent(String.self, forKey: .runtimeVersion)
        self.supportsDirectInference = try container.decode(Bool.self, forKey: .supportsDirectInference)
        self.supportsCacheBuild = try container.decode(Bool.self, forKey: .supportsCacheBuild)
        self.supportsCacheLoad = try container.decode(Bool.self, forKey: .supportsCacheLoad)
        self.supportedFeatures = try container.decodeIfPresent([BackendRuntimeFeature].self, forKey: .supportedFeatures) ?? []
        self.unavailableFeatures = try container.decodeIfPresent([UnavailableBackendFeature].self, forKey: .unavailableFeatures) ?? []
    }
}

public struct ExternalCapabilitiesResponse: Codable, Hashable, Sendable {
    public static let schemaVersion = "esh.capabilities.v1"

    public var schemaVersion: String
    public var tool: String
    public var toolVersion: String?
    public var commands: [ExternalCommandDescriptor]
    public var backends: [ExternalBackendCapability]
    public var installedModels: [ExternalInstalledModelCapability]

    public init(
        schemaVersion: String = ExternalCapabilitiesResponse.schemaVersion,
        tool: String = "esh",
        toolVersion: String? = nil,
        commands: [ExternalCommandDescriptor],
        backends: [ExternalBackendCapability],
        installedModels: [ExternalInstalledModelCapability]
    ) {
        self.schemaVersion = schemaVersion
        self.tool = tool
        self.toolVersion = toolVersion
        self.commands = commands
        self.backends = backends
        self.installedModels = installedModels
    }
}

public struct ExternalInferenceMessage: Codable, Hashable, Sendable {
    public var role: Message.Role
    public var text: String

    public init(role: Message.Role, text: String) {
        self.role = role
        self.text = text
    }
}

public struct ExternalInferenceRequest: Codable, Hashable, Sendable {
    public static let schemaVersion = "esh.infer.request.v1"

    public var schemaVersion: String
    public var model: String?
    public var cacheArtifactID: UUID?
    public var sessionName: String?
    public var cacheMode: CacheMode?
    public var intent: SessionIntent?
    public var messages: [ExternalInferenceMessage]
    public var generation: GenerationConfig
    public var routing: RoutingConfiguration?

    public init(
        schemaVersion: String = ExternalInferenceRequest.schemaVersion,
        model: String? = nil,
        cacheArtifactID: UUID? = nil,
        sessionName: String? = nil,
        cacheMode: CacheMode? = nil,
        intent: SessionIntent? = nil,
        messages: [ExternalInferenceMessage],
        generation: GenerationConfig = .init(),
        routing: RoutingConfiguration? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.model = model
        self.cacheArtifactID = cacheArtifactID
        self.sessionName = sessionName
        self.cacheMode = cacheMode
        self.intent = intent
        self.messages = messages
        self.generation = generation
        self.routing = routing
    }
}

public struct ExternalInferenceIntegration: Codable, Hashable, Sendable {
    public var mode: String
    public var cacheArtifactID: UUID?
    public var cacheMode: CacheMode?

    public init(mode: String, cacheArtifactID: UUID? = nil, cacheMode: CacheMode? = nil) {
        self.mode = mode
        self.cacheArtifactID = cacheArtifactID
        self.cacheMode = cacheMode
    }
}

public struct ExternalInferenceResponse: Codable, Hashable, Sendable {
    public static let schemaVersion = "esh.infer.response.v1"

    public var schemaVersion: String
    public var modelID: String
    public var backend: BackendKind
    public var integration: ExternalInferenceIntegration
    public var outputText: String
    public var metrics: Metrics
    public var routing: RoutingTrace?

    public init(
        schemaVersion: String = ExternalInferenceResponse.schemaVersion,
        modelID: String,
        backend: BackendKind,
        integration: ExternalInferenceIntegration,
        outputText: String,
        metrics: Metrics,
        routing: RoutingTrace? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.modelID = modelID
        self.backend = backend
        self.integration = integration
        self.outputText = outputText
        self.metrics = metrics
        self.routing = routing
    }
}
