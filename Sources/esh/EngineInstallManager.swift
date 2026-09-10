import Foundation
import EshCore

/// Tracks in-flight generative-engine installs for the Web Experience + agent. The client starts an install
/// (POST /v1/engines/install), polls status (GET /v1/engines/install?id=…), and can cancel
/// (POST /v1/engines/install/cancel). The actual venv/pip work lives in `GenerativeEngineManager` — this only
/// tracks phase so a stateless JSON endpoint can report progress, mirroring `InstallManager` for models.
actor EngineInstallManager {
    struct Status: Encodable, Sendable {
        var engineId: String
        var phase: String            // resolving | creating-env | installing | verifying | installed | failed | cancelled
        var detail: String?
        var error: String?
    }

    private struct Entry { var status: Status; var task: Task<Void, Never>? }
    private var entries: [String: Entry] = [:]
    private let manager: GenerativeEngineManager

    init(root: PersistenceRoot) { self.manager = GenerativeEngineManager(root: root) }

    func start(engineId: String) {
        guard let spec = GenerativeEngineCatalog.all.first(where: { $0.id.rawValue == engineId }) else { return }
        if let phase = entries[engineId]?.status.phase, ["resolving", "creating-env", "installing", "verifying"].contains(phase) { return }
        entries[engineId] = Entry(status: Status(engineId: engineId, phase: "resolving"), task: nil)
        let task = Task { [manager] in
            do {
                try manager.install(spec) { progress in
                    Task { await self.update(engineId: engineId, phase: progress.phase.rawValue, detail: progress.detail) }
                }
                await self.finish(engineId: engineId)
            } catch is CancellationError {
                await self.markCancelled(engineId: engineId)
            } catch {
                await self.fail(engineId: engineId, error: error.localizedDescription)
            }
        }
        entries[engineId]?.task = task
    }

    private func update(engineId: String, phase: String, detail: String?) {
        guard var e = entries[engineId] else { return }
        e.status.phase = phase; e.status.detail = detail; entries[engineId] = e
    }
    private func finish(engineId: String) {
        guard var e = entries[engineId] else { return }
        e.status.phase = "installed"; e.status.detail = nil; e.task = nil; entries[engineId] = e
    }
    private func fail(engineId: String, error: String) {
        guard var e = entries[engineId] else { return }
        e.status.phase = "failed"; e.status.error = error; e.task = nil; entries[engineId] = e
    }
    private func markCancelled(engineId: String) {
        guard var e = entries[engineId] else { return }
        e.status.phase = "cancelled"; e.task = nil; entries[engineId] = e
    }

    func cancel(engineId: String) { entries[engineId]?.task?.cancel() }
    func status(engineId: String) -> Status? { entries[engineId]?.status }
}
