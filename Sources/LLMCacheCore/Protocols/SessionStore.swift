import Foundation

public protocol SessionStore: Sendable {
    func save(session: ChatSession) throws
    func loadSession(id: UUID) throws -> ChatSession
    func listSessions() throws -> [ChatSession]
    func removeSession(id: UUID) throws
}
