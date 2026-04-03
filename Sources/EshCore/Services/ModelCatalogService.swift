import Foundation

public struct ModelCatalogService: Sendable {
    public enum SourceFilter: String, Sendable, CaseIterable {
        case all
        case local
        case hf
    }

    private let localCatalog: ModelCatalog
    private let huggingFaceCatalog: ModelCatalog
    private let modelStore: ModelStore

    public init(
        localCatalog: ModelCatalog,
        huggingFaceCatalog: ModelCatalog,
        modelStore: ModelStore
    ) {
        self.localCatalog = localCatalog
        self.huggingFaceCatalog = huggingFaceCatalog
        self.modelStore = modelStore
    }

    public func search(
        query: String,
        sourceFilter: SourceFilter = .all,
        limit: Int = 10
    ) async throws -> [ModelSearchResult] {
        let cappedLimit = max(1, limit)
        let installed = try modelStore.listInstalls()
        let installedByRepo = Dictionary(
            uniqueKeysWithValues: installed.map { ($0.spec.source.reference.lowercased(), $0) }
        )
        let installedByID = Dictionary(
            uniqueKeysWithValues: installed.map { ($0.id.lowercased(), $0) }
        )

        let localResults: [ModelSearchResult]
        let remoteResults: [ModelSearchResult]

        switch sourceFilter {
        case .all:
            async let local = localCatalog.search(query: query, limit: cappedLimit)
            async let remote = huggingFaceCatalog.search(query: query, limit: cappedLimit)
            localResults = try await local
            remoteResults = try await remote
        case .local:
            localResults = try await localCatalog.search(query: query, limit: cappedLimit)
            remoteResults = []
        case .hf:
            localResults = []
            remoteResults = try await huggingFaceCatalog.search(query: query, limit: cappedLimit)
        }

        let annotatedRemote = remoteResults.map { result in
            annotate(result: result, installedByRepo: installedByRepo, installedByID: installedByID)
        }

        let merged = deduplicate(localResults + annotatedRemote)
        return Array(merged.prefix(cappedLimit))
    }

    private func annotate(
        result: ModelSearchResult,
        installedByRepo: [String: ModelInstall],
        installedByID: [String: ModelInstall]
    ) -> ModelSearchResult {
        var result = result
        if let install = installedByRepo[result.modelSource.reference.lowercased()]
            ?? installedByID[result.id.lowercased()] {
            result.isInstalled = true
            result.installedModelID = install.id
            result.installPath = install.installPath
        }
        return result
    }

    private func deduplicate(_ results: [ModelSearchResult]) -> [ModelSearchResult] {
        var seen: Set<String> = []
        var deduped: [ModelSearchResult] = []

        for result in results {
            let key = result.modelSource.reference.lowercased()
            if seen.insert(key).inserted {
                deduped.append(result)
            }
        }

        return deduped.sorted { lhs, rhs in
            if lhs.isInstalled != rhs.isInstalled {
                return lhs.isInstalled && !rhs.isInstalled
            }
            if lhs.source != rhs.source {
                return lhs.source == .local
            }
            return (lhs.downloads ?? 0) > (rhs.downloads ?? 0)
        }
    }
}
