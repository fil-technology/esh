import Foundation

public struct FileContextPackageStore: ContextPackageStore, Sendable {
    private let root: PersistenceRoot
    private let manifestIO: ContextPackageManifestIO

    public init(
        root: PersistenceRoot = .default(),
        manifestIO: ContextPackageManifestIO = .init()
    ) {
        self.root = root
        self.manifestIO = manifestIO
    }

    public func savePackage(_ package: ContextPackage, workspaceRootURL: URL) throws {
        try ensureDirectories(workspaceRootURL: workspaceRootURL)
        let url = packageURL(for: package.id, workspaceRootURL: workspaceRootURL)
        let data = try JSONCoding.encoder.encode(package)
        var stored = package
        stored.packagePath = url.path
        stored.sizeBytes = Int64(data.count)
        try manifestIO.write(stored, to: url)
    }

    public func loadPackage(id: UUID, workspaceRootURL: URL) throws -> ContextPackage {
        let url = packageURL(for: id, workspaceRootURL: workspaceRootURL)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StoreError.notFound("Context package \(id.uuidString) was not found.")
        }
        return try manifestIO.read(from: url)
    }

    public func listPackages(workspaceRootURL: URL) throws -> [ContextPackage] {
        try ensureDirectories(workspaceRootURL: workspaceRootURL)
        return try FileManager.default.contentsOfDirectory(at: directoryURL(workspaceRootURL: workspaceRootURL), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try manifestIO.read(from: $0) }
            .sorted { $0.manifest.createdAt > $1.manifest.createdAt }
    }

    public func removePackage(id: UUID, workspaceRootURL: URL) throws {
        let url = packageURL(for: id, workspaceRootURL: workspaceRootURL)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func ensureDirectories(workspaceRootURL: URL) throws {
        try FileManager.default.createDirectory(at: directoryURL(workspaceRootURL: workspaceRootURL), withIntermediateDirectories: true)
    }

    private func directoryURL(workspaceRootURL: URL) -> URL {
        root.rootURL
            .appendingPathComponent("context-packages", isDirectory: true)
            .appendingPathComponent(Fingerprint.sha256([workspaceRootURL.path]), isDirectory: true)
    }

    private func packageURL(for id: UUID, workspaceRootURL: URL) -> URL {
        directoryURL(workspaceRootURL: workspaceRootURL).appendingPathComponent("\(id.uuidString).json")
    }
}
