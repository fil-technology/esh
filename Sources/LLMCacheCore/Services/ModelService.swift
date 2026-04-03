import Foundation

public struct ModelService: Sendable {
    private let store: ModelStore
    private let downloader: ModelDownloader

    public init(store: ModelStore, downloader: ModelDownloader) {
        self.store = store
        self.downloader = downloader
    }

    public func install(
        repoID: String,
        suggestedID: String? = nil,
        progress: @escaping @Sendable (DownloadState) -> Void
    ) async throws -> ModelManifest {
        try await downloader.install(
            source: ModelSource(kind: .huggingFace, reference: repoID),
            suggestedID: suggestedID,
            progress: progress
        )
    }

    public func list() throws -> [ModelInstall] {
        try store.listInstalls()
    }

    public func inspect(id: String) throws -> ModelManifest {
        try store.loadManifest(id: id)
    }

    public func remove(id: String) throws {
        try store.removeInstall(id: id)
    }
}
