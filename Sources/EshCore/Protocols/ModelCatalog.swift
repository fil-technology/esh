import Foundation

public protocol ModelCatalog: Sendable {
    func search(query: String, limit: Int) async throws -> [ModelSearchResult]
}
