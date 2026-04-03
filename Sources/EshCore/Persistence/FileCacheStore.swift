import Foundation

public struct FileCacheStore: CacheStore, Sendable {
    private let manifestsURL: URL
    private let payloadsURL: URL
    private let manifestIO: ArtifactManifestIO

    public init(
        root: PersistenceRoot = .default(),
        manifestIO: ArtifactManifestIO = .init()
    ) {
        self.manifestsURL = root.cachesURL.appendingPathComponent("manifests", isDirectory: true)
        self.payloadsURL = root.cachesURL.appendingPathComponent("payloads", isDirectory: true)
        self.manifestIO = manifestIO
    }

    public func saveArtifact(_ artifact: CacheArtifact, payload: Data) throws {
        try ensureDirectories()
        let payloadURL = payloadURL(for: artifact.id)
        try payload.write(to: payloadURL, options: .atomic)

        var stored = artifact
        stored.artifactPath = payloadURL.path
        stored.sizeBytes = Int64(payload.count)
        try manifestIO.write(stored, to: manifestURL(for: artifact.id))
    }

    public func loadArtifact(id: UUID) throws -> (CacheArtifact, Data) {
        let manifestURL = manifestURL(for: id)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw StoreError.notFound("Cache artifact \(id.uuidString) was not found.")
        }

        let artifact = try manifestIO.read(from: manifestURL)
        let payloadURL = URL(fileURLWithPath: artifact.artifactPath)
        guard FileManager.default.fileExists(atPath: payloadURL.path) else {
            throw StoreError.invalidManifest("Cache payload is missing for artifact \(id.uuidString).")
        }

        let data = try Data(contentsOf: payloadURL)
        return (artifact, data)
    }

    public func listArtifacts() throws -> [CacheArtifact] {
        try ensureDirectories()
        return try FileManager.default.contentsOfDirectory(at: manifestsURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try manifestIO.read(from: $0) }
            .sorted { $0.manifest.createdAt > $1.manifest.createdAt }
    }

    public func removeArtifact(id: UUID) throws {
        let manifestURL = manifestURL(for: id)
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let artifact = try manifestIO.read(from: manifestURL)
            let payloadURL = URL(fileURLWithPath: artifact.artifactPath)
            if FileManager.default.fileExists(atPath: payloadURL.path) {
                try FileManager.default.removeItem(at: payloadURL)
            }
            try FileManager.default.removeItem(at: manifestURL)
            return
        }

        let payloadURL = payloadURL(for: id)
        if FileManager.default.fileExists(atPath: payloadURL.path) {
            try FileManager.default.removeItem(at: payloadURL)
        }
    }

    private func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: manifestsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: payloadsURL, withIntermediateDirectories: true)
    }

    private func manifestURL(for id: UUID) -> URL {
        manifestsURL.appendingPathComponent("\(id.uuidString).json")
    }

    private func payloadURL(for id: UUID) -> URL {
        payloadsURL.appendingPathComponent("\(id.uuidString).bin")
    }
}
