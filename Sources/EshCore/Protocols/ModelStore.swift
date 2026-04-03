import Foundation

public protocol ModelStore: Sendable {
    func save(manifest: ModelManifest) throws
    func loadManifest(id: String) throws -> ModelManifest
    func listInstalls() throws -> [ModelInstall]
    func removeInstall(id: String) throws
    func prepareInstallDirectory(id: String) throws -> URL
}
