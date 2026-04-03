import Foundation

public protocol CacheStore: Sendable {
    func saveArtifact(_ artifact: CacheArtifact, payload: Data) throws
    func loadArtifact(id: UUID) throws -> (CacheArtifact, Data)
    func listArtifacts() throws -> [CacheArtifact]
    func removeArtifact(id: UUID) throws
}
