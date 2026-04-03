import Foundation

public struct FileModelStore: ModelStore, Sendable {
    private let manifestsURL: URL
    private let installsURL: URL
    private let manifestIO: ModelManifestIO

    public init(
        root: PersistenceRoot = .default(),
        manifestIO: ModelManifestIO = .init()
    ) {
        self.manifestsURL = root.modelsURL.appendingPathComponent("manifests", isDirectory: true)
        self.installsURL = root.modelsURL.appendingPathComponent("installs", isDirectory: true)
        self.manifestIO = manifestIO
    }

    public func save(manifest: ModelManifest) throws {
        try ensureDirectories()
        try manifestIO.write(manifest, to: manifestURL(for: manifest.install.id))
        try ensureInstallDirectory(for: manifest.install.id)
    }

    public func loadManifest(id: String) throws -> ModelManifest {
        let url = manifestURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StoreError.notFound("Model manifest \(id) was not found.")
        }
        return try manifestIO.read(from: url)
    }

    public func listInstalls() throws -> [ModelInstall] {
        try ensureDirectories()
        return try FileManager.default.contentsOfDirectory(at: manifestsURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try manifestIO.read(from: $0).install }
            .sorted { $0.installedAt > $1.installedAt }
    }

    public func removeInstall(id: String) throws {
        let manifestURL = manifestURL(for: id)
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            try FileManager.default.removeItem(at: manifestURL)
        }

        let installURL = installsURL.appendingPathComponent(id, isDirectory: true)
        if FileManager.default.fileExists(atPath: installURL.path) {
            try FileManager.default.removeItem(at: installURL)
        }
    }

    public func prepareInstallDirectory(id: String) throws -> URL {
        try ensureDirectories()
        let url = installsURL.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: manifestsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installsURL, withIntermediateDirectories: true)
    }

    private func ensureInstallDirectory(for id: String) throws {
        let url = installsURL.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func manifestURL(for id: String) -> URL {
        manifestsURL.appendingPathComponent("\(id).json")
    }
}
