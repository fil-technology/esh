import Foundation

public struct FileSessionStore: SessionStore, Sendable {
    private let directoryURL: URL

    public init(root: PersistenceRoot = .default()) {
        self.directoryURL = root.sessionsURL
    }

    public func save(session: ChatSession) throws {
        try ensureDirectory()
        let data = try JSONCoding.encoder.encode(session)
        try data.write(to: fileURL(for: session.id), options: .atomic)
    }

    public func loadSession(id: UUID) throws -> ChatSession {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StoreError.notFound("Session \(id.uuidString) was not found.")
        }
        let data = try Data(contentsOf: url)
        return try JSONCoding.decoder.decode(ChatSession.self, from: data)
    }

    public func listSessions() throws -> [ChatSession] {
        try ensureDirectory()
        return try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try Data(contentsOf: $0) }
            .map { try JSONCoding.decoder.decode(ChatSession.self, from: $0) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func removeSession(id: UUID) throws {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).json")
    }
}
