import Foundation

/// A durable record of one agent turn.
public struct TurnRecord: Codable, Sendable, Hashable {
    public let id: UUID
    public let role: String
    public let text: String
    public let createdAt: Date
    public var tokenCount: Int?

    public init(id: UUID = UUID(), role: String, text: String, createdAt: Date = Date(), tokenCount: Int? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.tokenCount = tokenCount
    }
}

/// Errors thrown by `SessionStore`.
public enum StoreError: Error, Equatable {
    case notFound(UUID)
    case corrupt(path: String)
    case quotaExceeded(bytes: Int)
}

/// SessionStore keeps agent sessions on disk, one JSON file per session, and an in-memory index so listing is
/// cheap. All mutation goes through the actor so concurrent turns cannot interleave writes.
public actor SessionStore {
    public struct Summary: Codable, Sendable, Hashable {
        public let id: UUID
        public var title: String
        public var turnCount: Int
        public var updatedAt: Date
        public var bytes: Int
    }

    private let directory: URL
    private let byteQuota: Int
    private var index: [UUID: Summary] = [:]
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Creates a SessionStore rooted at `directory`, creating it when needed.
    public init(directory: URL, byteQuota: Int = 512 * 1024 * 1024) throws {
        self.directory = directory
        self.byteQuota = byteQuota
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys]
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    /// Rebuilds the in-memory index from disk. Corrupt files are skipped, not fatal.
    public func reloadIndex() throws -> Int {
        index.removeAll()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let turns = try? decoder.decode([TurnRecord].self, from: data),
                  let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
            index[id] = Summary(id: id,
                                title: Self.title(for: turns),
                                turnCount: turns.count,
                                updatedAt: turns.last?.createdAt ?? Date.distantPast,
                                bytes: data.count)
        }
        return index.count
    }

    /// Appends a turn to a session, creating the session on first write.
    public func append(_ turn: TurnRecord, to id: UUID) throws -> Summary {
        var turns = (try? load(id)) ?? []
        turns.append(turn)
        let data = try encoder.encode(turns)
        let projected = totalBytes() - (index[id]?.bytes ?? 0) + data.count
        guard projected <= byteQuota else { throw StoreError.quotaExceeded(bytes: projected) }
        try data.write(to: url(for: id), options: .atomic)
        let summary = Summary(id: id, title: Self.title(for: turns), turnCount: turns.count,
                              updatedAt: turn.createdAt, bytes: data.count)
        index[id] = summary
        return summary
    }

    /// Loads every turn of a session.
    public func load(_ id: UUID) throws -> [TurnRecord] {
        let file = url(for: id)
        guard FileManager.default.fileExists(atPath: file.path) else { throw StoreError.notFound(id) }
        let data = try Data(contentsOf: file)
        do {
            return try decoder.decode([TurnRecord].self, from: data)
        } catch {
            throw StoreError.corrupt(path: file.path)
        }
    }

    /// Sessions, most recently updated first.
    public func list(limit: Int = 50) -> [Summary] {
        Array(index.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    }

    /// Removes a session. Removing an unknown session is a no-op.
    public func remove(_ id: UUID) throws {
        let file = url(for: id)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        index[id] = nil
    }

    /// Drops the oldest sessions until the store is under `fraction` of its quota.
    public func compact(to fraction: Double = 0.8) throws -> [UUID] {
        var removed: [UUID] = []
        let target = Int(Double(byteQuota) * fraction)
        for summary in index.values.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            guard totalBytes() > target else { break }
            try remove(summary.id)
            removed.append(summary.id)
        }
        return removed
    }

    private func totalBytes() -> Int {
        index.values.reduce(0) { $0 + $1.bytes }
    }

    private static func title(for turns: [TurnRecord]) -> String {
        guard let first = turns.first(where: { $0.role == "user" }) else { return "Untitled" }
        let words = first.text.split(separator: " ").prefix(8)
        return words.joined(separator: " ")
    }
}

extension SessionStore {
    /// Convenience used by tests and the CLI: a SessionStore in a fresh temporary directory.
    public static func temporary() throws -> SessionStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-\(UUID().uuidString)")
        return try SessionStore(directory: dir)
    }
}
