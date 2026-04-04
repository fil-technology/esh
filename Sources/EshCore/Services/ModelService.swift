import Foundation

public struct ModelService: Sendable {
    private let store: ModelStore
    private let downloader: ModelDownloader
    private let recommendedRegistry: RecommendedModelRegistry

    public init(
        store: ModelStore,
        downloader: ModelDownloader,
        recommendedRegistry: RecommendedModelRegistry = RecommendedModelRegistry()
    ) {
        self.store = store
        self.downloader = downloader
        self.recommendedRegistry = recommendedRegistry
    }

    public func install(
        repoID: String,
        suggestedID: String? = nil,
        variant: String? = nil,
        progress: @escaping @Sendable (DownloadState) -> Void
    ) async throws -> ModelManifest {
        try await downloader.install(
            source: ModelSource(kind: .huggingFace, reference: repoID),
            suggestedID: suggestedID,
            variant: variant,
            progress: progress
        )
    }

    public func list() throws -> [ModelInstall] {
        try store.listInstalls()
    }

    public func listRecommended(
        profile: RecommendedModel.Profile? = nil,
        tier: RecommendedModel.Tier? = nil,
        backend: BackendKind? = nil,
        tag: String? = nil
    ) -> [RecommendedModel] {
        recommendedRegistry.list(profile: profile, tier: tier, backend: backend, tag: tag)
    }

    public func resolveRecommended(alias: String) -> RecommendedModel? {
        recommendedRegistry.resolve(alias: alias)
    }

    public func inspect(id: String) throws -> ModelManifest {
        try store.loadManifest(id: id)
    }

    public func remove(id: String) throws {
        try store.removeInstall(id: id)
    }
}
