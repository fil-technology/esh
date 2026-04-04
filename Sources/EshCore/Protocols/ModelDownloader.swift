import Foundation

public protocol ModelDownloader: Sendable {
    func install(
        source: ModelSource,
        suggestedID: String?,
        variant: String?,
        progress: @escaping @Sendable (DownloadState) -> Void
    ) async throws -> ModelManifest
}
