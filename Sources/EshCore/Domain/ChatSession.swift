import Foundation

public struct ChatSession: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var modelID: String?
    public var backend: BackendKind?
    public var cacheMode: CacheMode?
    public var intent: SessionIntent?
    public var autosaveEnabled: Bool?
    public var messages: [Message]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        modelID: String? = nil,
        backend: BackendKind? = nil,
        cacheMode: CacheMode? = nil,
        intent: SessionIntent? = nil,
        autosaveEnabled: Bool? = nil,
        messages: [Message] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.modelID = modelID
        self.backend = backend
        self.cacheMode = cacheMode
        self.intent = intent
        self.autosaveEnabled = autosaveEnabled
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
