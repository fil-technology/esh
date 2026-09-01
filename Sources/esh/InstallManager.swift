import Foundation
import EshCore

/// Tracks in-flight model installs for the Web Experience. The browser starts an install
/// (POST /v1/models/install), then polls status (GET /v1/models/install?repo=…); cancellation is
/// POST /v1/models/install/cancel. All download/verify logic stays in the canonical services — this
/// only tracks progress state so a stateless JSON endpoint can report it.
actor InstallManager {
    struct Status: Encodable, Sendable {
        var repoID: String
        var phase: String            // resolving | downloading | verifying | installed | failed | cancelled
        var bytesDownloaded: Int64
        var totalBytes: Int64?
        var percent: Int?
        var installedID: String?
        var error: String?
    }

    private struct Entry { var status: Status; var task: Task<Void, Never>? }
    private var entries: [String: Entry] = [:]

    private let service: ModelService

    init(root: PersistenceRoot) {
        let store = FileModelStore(root: root)
        self.service = ModelService(store: store, downloader: HuggingFaceModelDownloader(modelStore: store, storageRoot: root))
    }

    func start(repoID: String, variant: String?) {
        if let existing = entries[repoID]?.status.phase, existing == "downloading" || existing == "resolving" { return }
        var status = Status(repoID: repoID, phase: "resolving", bytesDownloaded: 0, totalBytes: nil, percent: 0)
        let task = Task { [service] in
            do {
                let manifest = try await service.install(repoID: repoID, variant: variant) { state in
                    Task { await self.update(repoID: repoID, state: state) }
                }
                await self.finish(repoID: repoID, installedID: manifest.install.id)
            } catch is CancellationError {
                await self.markCancelled(repoID: repoID)
            } catch {
                await self.fail(repoID: repoID, error: error.localizedDescription)
            }
        }
        entries[repoID] = Entry(status: status, task: task)
    }

    private func update(repoID: String, state: DownloadState) {
        guard var e = entries[repoID] else { return }
        e.status.phase = state.phase.rawValue
        e.status.bytesDownloaded = state.bytesDownloaded
        e.status.totalBytes = state.totalBytes
        if let total = state.totalBytes, total > 0 { e.status.percent = Int(Double(state.bytesDownloaded) / Double(total) * 100) }
        entries[repoID] = e
    }

    private func finish(repoID: String, installedID: String) {
        guard var e = entries[repoID] else { return }
        e.status.phase = "installed"; e.status.percent = 100; e.status.installedID = installedID; e.task = nil
        entries[repoID] = e
    }

    private func fail(repoID: String, error: String) {
        guard var e = entries[repoID] else { return }
        e.status.phase = "failed"; e.status.error = error; e.task = nil
        entries[repoID] = e
    }

    private func markCancelled(repoID: String) {
        guard var e = entries[repoID] else { return }
        e.status.phase = "cancelled"; e.task = nil
        entries[repoID] = e
    }

    func cancel(repoID: String) {
        entries[repoID]?.task?.cancel()
    }

    func status(repoID: String) -> Status? { entries[repoID]?.status }
}
