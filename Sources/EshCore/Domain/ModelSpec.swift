import Foundation

public struct ModelSpec: Codable, Hashable, Sendable {
    public var id: String
    public var displayName: String
    public var backend: BackendKind
    public var source: ModelSource
    public var localPath: String?
    public var tokenizerID: String?
    public var architectureFingerprint: String?
    public var variant: String?
    public var task: ModelTask
    public var inputModalities: [ModelModality]
    public var outputModalities: [ModelModality]
    public var capabilities: ModelCapabilities

    public init(
        id: String,
        displayName: String,
        backend: BackendKind,
        source: ModelSource,
        localPath: String? = nil,
        tokenizerID: String? = nil,
        architectureFingerprint: String? = nil,
        variant: String? = nil,
        task: ModelTask = .text,
        inputModalities: [ModelModality] = [.text],
        outputModalities: [ModelModality] = [.text],
        capabilities: ModelCapabilities = .textGeneration
    ) {
        self.id = id
        self.displayName = displayName
        self.backend = backend
        self.source = source
        self.localPath = localPath
        self.tokenizerID = tokenizerID
        self.architectureFingerprint = architectureFingerprint
        self.variant = variant
        self.task = task
        self.inputModalities = inputModalities
        self.outputModalities = outputModalities
        self.capabilities = capabilities
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case backend
        case source
        case localPath
        case tokenizerID
        case architectureFingerprint
        case variant
        case task
        case inputModalities
        case outputModalities
        case capabilities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.backend = try container.decode(BackendKind.self, forKey: .backend)
        self.source = try container.decode(ModelSource.self, forKey: .source)
        self.localPath = try container.decodeIfPresent(String.self, forKey: .localPath)
        self.tokenizerID = try container.decodeIfPresent(String.self, forKey: .tokenizerID)
        self.architectureFingerprint = try container.decodeIfPresent(String.self, forKey: .architectureFingerprint)
        self.variant = try container.decodeIfPresent(String.self, forKey: .variant)
        self.task = try container.decodeIfPresent(ModelTask.self, forKey: .task) ?? .text
        self.inputModalities = try container.decodeIfPresent([ModelModality].self, forKey: .inputModalities) ?? [.text]
        self.outputModalities = try container.decodeIfPresent([ModelModality].self, forKey: .outputModalities) ?? [.text]
        self.capabilities = try container.decodeIfPresent(ModelCapabilities.self, forKey: .capabilities) ?? .textGeneration
    }
}
