import Foundation

public protocol ContextPackageStore: Sendable {
    func savePackage(_ package: ContextPackage, workspaceRootURL: URL) throws
    func loadPackage(id: UUID, workspaceRootURL: URL) throws -> ContextPackage
    func listPackages(workspaceRootURL: URL) throws -> [ContextPackage]
    func removePackage(id: UUID, workspaceRootURL: URL) throws
}
