import Foundation

public struct Message: Identifiable, Codable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable, CaseIterable {
        case system
        case user
        case assistant
        case tool
    }

    public let id: UUID
    public var role: Role
    public var text: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}
