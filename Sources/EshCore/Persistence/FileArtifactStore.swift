import Foundation
import CryptoKit

// esh 2.1 UCMR, Stage 0 — persistent store for typed generated artifacts. Each artifact lives under
// `artifactsURL/<uuid>/` as `manifest.json` + its files. Binary/media results are stored as bytes here
// and served by reference (GET /v1/artifacts/{id}), never base64-in-JSON. Unrelated to the prompt-cache
// `CacheArtifact`.

public enum ArtifactStoreError: Error, LocalizedError, Equatable {
    case invalidPath(String)
    case notFound(UUID)

    public var errorDescription: String? {
        switch self {
        case let .invalidPath(p): return "Unsafe artifact file path: \(p)"
        case let .notFound(id): return "Artifact not found: \(id.uuidString)"
        }
    }
}

public protocol ArtifactStore: Sendable {
    /// Persist an artifact plus its file bytes (keyed by relative path). Returns the finalized artifact
    /// with `files` recomputed (byte sizes + sha256). `files` may be empty for metadata-only artifacts.
    @discardableResult
    func save(_ artifact: Artifact, files: [String: Data]) throws -> Artifact
    func load(id: UUID) throws -> Artifact?
    func data(id: UUID, file: String) throws -> Data?
    func list() throws -> [Artifact]
    func delete(id: UUID) throws
}

public struct FileArtifactStore: ArtifactStore {
    private let rootURL: URL
    private var fileManager: FileManager { .default }

    public init(root: PersistenceRoot) {
        self.rootURL = root.artifactsURL
    }

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    private func directory(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Reject absolute paths and any `..` traversal; normalize separators.
    static func sanitizedRelativePath(_ path: String) -> String? {
        if path.hasPrefix("/") { return nil }
        let comps = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if comps.isEmpty || comps.contains("..") || comps.contains(".") { return nil }
        return comps.joined(separator: "/")
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    public func save(_ artifact: Artifact, files: [String: Data]) throws -> Artifact {
        let dir = directory(for: artifact.id)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        var written: [ArtifactFile] = []
        for (path, data) in files {
            guard let safe = Self.sanitizedRelativePath(path) else { throw ArtifactStoreError.invalidPath(path) }
            let fileURL = dir.appendingPathComponent(safe)
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            written.append(ArtifactFile(relativePath: safe, byteSize: data.count, sha256: Self.sha256Hex(data)))
        }

        var finalized = artifact
        // When bytes are provided, the store is the source of truth for `files`; otherwise keep the
        // caller's (possibly empty) list for metadata-only artifacts.
        if !files.isEmpty { finalized.files = written.sorted { $0.relativePath < $1.relativePath } }
        let manifest = try encoder.encode(finalized)
        try manifest.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
        return finalized
    }

    public func load(id: UUID) throws -> Artifact? {
        let url = directory(for: id).appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(Artifact.self, from: Data(contentsOf: url))
    }

    public func data(id: UUID, file: String) throws -> Data? {
        guard let safe = Self.sanitizedRelativePath(file) else { throw ArtifactStoreError.invalidPath(file) }
        let dir = directory(for: id)
        let url = dir.appendingPathComponent(safe)
        // Defense in depth: the resolved path must stay inside the artifact's own directory.
        guard url.standardizedFileURL.path.hasPrefix(dir.standardizedFileURL.path + "/") else {
            throw ArtifactStoreError.invalidPath(file)
        }
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func list() throws -> [Artifact] {
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }
        let dirs = try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
        var out: [Artifact] = []
        for dir in dirs {
            guard let id = UUID(uuidString: dir.lastPathComponent) else { continue }
            if let a = try? load(id: id) { out.append(a) }
        }
        return out.sorted { $0.createdAt > $1.createdAt }
    }

    public func delete(id: UUID) throws {
        let dir = directory(for: id)
        guard fileManager.fileExists(atPath: dir.path) else { return }
        try fileManager.removeItem(at: dir)
    }
}
