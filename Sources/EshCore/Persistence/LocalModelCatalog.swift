import Foundation

public struct LocalModelCatalog: ModelCatalog, Sendable {
    private let store: ModelStore

    public init(store: ModelStore) {
        self.store = store
    }

    public func search(query: String, limit: Int) async throws -> [ModelSearchResult] {
        let installs = try store.listInstalls()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        let matches = installs.filter { install in
            guard !trimmed.isEmpty else { return true }
            let haystacks = [
                install.id,
                install.spec.displayName,
                install.spec.source.reference,
                install.backendFormat
            ].map { $0.lowercased() }
            let needle = trimmed.lowercased()
            return haystacks.contains { $0.contains(needle) }
        }

        return Array(matches.prefix(limit)).map { install in
            ModelSearchResult(
                id: install.id,
                source: .local,
                modelSource: install.spec.source,
                displayName: install.spec.displayName,
                summary: "Installed locally",
                backend: install.spec.backend,
                sizeBytes: install.sizeBytes,
                tags: [install.backendFormat],
                updatedAt: install.installedAt,
                isInstalled: true,
                installedModelID: install.id,
                installPath: install.installPath
            )
        }
    }
}
