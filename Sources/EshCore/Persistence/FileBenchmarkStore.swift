import Foundation

public struct FileBenchmarkStore: Sendable {
    private let directoryURL: URL

    public init(root: PersistenceRoot = .default()) {
        self.directoryURL = root.benchmarksURL
    }

    public func save(_ record: BenchmarkRecord) throws {
        try ensureDirectory()
        let data = try JSONCoding.encoder.encode(record)
        try data.write(to: fileURL(for: record.id), options: .atomic)
    }

    public func load(id: UUID) throws -> BenchmarkRecord {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StoreError.notFound("Benchmark \(id.uuidString) was not found.")
        }
        let data = try Data(contentsOf: url)
        return try JSONCoding.decoder.decode(BenchmarkRecord.self, from: data)
    }

    public func list() throws -> [BenchmarkRecord] {
        try ensureDirectory()
        return try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try Data(contentsOf: $0) }
            .map { try JSONCoding.decoder.decode(BenchmarkRecord.self, from: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).json")
    }
}
