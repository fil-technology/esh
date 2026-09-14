import Foundation

// esh RC follow-up — OS-managed, background-capable model downloading.
//
// This evolves the single download layer to a delegate-driven `URLSession` whose configuration is injected:
// production (iOS) uses `URLSessionConfiguration.background(withIdentifier:)` so iOS owns the transfer and
// continues it while the app is suspended; tests/CLI inject an ephemeral (foreground) config so the same
// code path runs deterministically in-process. It is NOT a second architecture — `LocalModelManager` owns
// one coordinator and the verify → atomic-install pipeline stays in the manager.
//
// Cross-relaunch: each download task is tagged with its model id (`taskDescription`) and a `PendingDownload`
// record is persisted next to the install dir. On a fresh runtime the coordinator recreates the session
// (same identifier), the OS re-delivers outstanding events, and `LocalModelManager.reconcile()` finalizes any
// transfer that completed while suspended. The host never needs to retain the original runtime object.

/// Persisted per-model download state, so a new runtime can reconstruct/reconnect after relaunch.
struct PendingDownload: Codable, Sendable {
    enum Phase: String, Codable, Sendable {
        case downloading          // task submitted / in flight
        case downloaded           // transfer complete, staged file present, awaiting verification
        case failed               // terminal failure (kept for reason surfacing; retry allowed)
    }
    var modelID: String
    var sourceURL: URL
    var expectedBytes: Int64
    var sha256: String
    var phase: Phase
    var stagedPath: String?       // model.download once the transfer completed
    var lastProgress: Double      // best-effort; may reset to 0 after relaunch (OS doesn't replay history)
    var reason: String?
    var updatedAt: Date
}

/// The terminal outcome of a transfer as seen by an in-process waiter.
enum DownloadTerminal: Sendable {
    case staged(URL)              // transfer complete; file staged at this URL, ready to verify
    case failed(String)
    case cancelled
}

final class ModelDownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    /// Stable background-session identifier (one per process). Must not change across app versions.
    static let backgroundIdentifier = "technology.fil.esh.model-downloads"

    private let installsRoot: URL
    private let makeConfiguration: @Sendable () -> URLSessionConfiguration
    private let lock = NSLock()
    private var waiters: [String: CheckedContinuation<DownloadTerminal, Never>] = [:]
    private var progress: [String: @Sendable (Double) -> Void] = [:]
    private var backgroundCompletion: (@Sendable () -> Void)?

    // The session is created once and reused (a background session is unique per identifier per process).
    private lazy var session: URLSession =
        URLSession(configuration: makeConfiguration(), delegate: self, delegateQueue: nil)

    init(installsRoot: URL, makeConfiguration: @escaping @Sendable () -> URLSessionConfiguration) {
        self.installsRoot = installsRoot
        self.makeConfiguration = makeConfiguration
        super.init()
    }

    // MARK: Paths

    private func dir(_ id: String) -> URL { installsRoot.appendingPathComponent(id, isDirectory: true) }
    private func recordURL(_ id: String) -> URL { dir(id).appendingPathComponent("download.json") }
    private func stagedURL(_ id: String) -> URL { dir(id).appendingPathComponent("model.download") }
    private func resumeURL(_ id: String) -> URL { dir(id).appendingPathComponent("model.resume") }

    // MARK: Records (persisted, for cross-relaunch reconstruction)

    func loadRecord(_ id: String) -> PendingDownload? {
        guard let data = try? Data(contentsOf: recordURL(id)) else { return nil }
        return try? JSONDecoder().decode(PendingDownload.self, from: data)
    }
    private func saveRecord(_ r: PendingDownload) {
        try? FileManager.default.createDirectory(at: dir(r.modelID), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(r) { try? data.write(to: recordURL(r.modelID), options: .atomic) }
    }
    func clearRecord(_ id: String) { try? FileManager.default.removeItem(at: recordURL(id)) }

    /// Ensure the (background) session exists so the OS re-delivers events for outstanding tasks after a
    /// relaunch. Safe to call repeatedly.
    func reconnect() { _ = session }

    /// Host hook plumbing (iOS `application(_:handleEventsForBackgroundURLSession:completionHandler:)`).
    func setBackgroundCompletion(_ handler: @escaping @Sendable () -> Void) {
        lock.lock(); backgroundCompletion = handler; lock.unlock()
        _ = session   // make sure the session is live to receive the queued events
    }

    // MARK: Start / await

    /// Begin (or resume) a download and suspend until this process observes a terminal event. If the process
    /// is terminated first, the persisted record + staged file let a later runtime finalize via reconcile();
    /// this call's caller is simply gone. Never throws — returns a typed `DownloadTerminal`.
    func download(modelID: String, url: URL, expectedBytes: Int64, sha256: String,
                  onProgress: @escaping @Sendable (Double) -> Void) async -> DownloadTerminal {
        await withCheckedContinuation { (cont: CheckedContinuation<DownloadTerminal, Never>) in
            lock.lock()
            waiters[modelID] = cont
            progress[modelID] = onProgress
            lock.unlock()

            saveRecord(PendingDownload(modelID: modelID, sourceURL: url, expectedBytes: expectedBytes,
                                       sha256: sha256, phase: .downloading, stagedPath: nil,
                                       lastProgress: 0, reason: nil, updatedAt: Date()))

            let resumeData = try? Data(contentsOf: resumeURL(modelID))
            let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
            task.taskDescription = modelID   // survives relaunch → identifies the model on reconnect
            task.resume()
        }
    }

    /// Cancel an in-flight download, persisting resume data so a later `download` continues rather than
    /// restarts. Resolves any in-process waiter as `.cancelled`.
    func cancel(modelID: String) {
        session.getAllTasks { tasks in
            for t in tasks where t.taskDescription == modelID {
                if let dl = t as? URLSessionDownloadTask {
                    dl.cancel(byProducingResumeData: { data in
                        if let data { try? data.write(to: self.resumeURL(modelID)) }
                    })
                } else { t.cancel() }
            }
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        lock.lock(); let cb = progress[id]; lock.unlock()
        cb?(p)
        if var r = loadRecord(id) { r.lastProgress = p; r.phase = .downloading; r.updatedAt = Date(); saveRecord(r) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temp file is valid only within this callback — move it to a stable staging path synchronously.
        guard let id = downloadTask.taskDescription else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        let staged = stagedURL(id)
        let fm = FileManager.default
        try? fm.createDirectory(at: dir(id), withIntermediateDirectories: true)
        try? fm.removeItem(at: staged)
        let moved = (try? fm.moveItem(at: location, to: staged)) != nil
        if var r = loadRecord(id) {
            if moved && (200...299).contains(status) {
                r.phase = .downloaded; r.stagedPath = staged.path; r.lastProgress = 1
            } else {
                r.phase = .failed; r.reason = moved ? "HTTP \(status)" : "could not stage downloaded file"
            }
            r.updatedAt = Date(); saveRecord(r)
        }
        // Success terminal is delivered from didCompleteWithError (error == nil) so we resume the waiter there.
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription else { return }
        if let error {
            let nsError = error as NSError
            if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                try? data.write(to: resumeURL(id))
            }
            let cancelled = nsError.code == NSURLErrorCancelled
            if var r = loadRecord(id) { r.phase = .failed; r.reason = cancelled ? "cancelled" : error.localizedDescription; r.updatedAt = Date(); saveRecord(r) }
            resumeWaiter(id, cancelled ? .cancelled : .failed(error.localizedDescription))
            return
        }
        // Success: the staged file was placed in didFinishDownloadingTo.
        if let r = loadRecord(id), r.phase == .downloaded, let path = r.stagedPath {
            resumeWaiter(id, .staged(URL(fileURLWithPath: path)))
        } else {
            resumeWaiter(id, .failed("download completed without a staged file"))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock(); let handler = backgroundCompletion; backgroundCompletion = nil; lock.unlock()
        if let handler { DispatchQueue.main.async { handler() } }
    }

    private func resumeWaiter(_ id: String, _ terminal: DownloadTerminal) {
        lock.lock(); let cont = waiters.removeValue(forKey: id); progress.removeValue(forKey: id); lock.unlock()
        cont?.resume(returning: terminal)
    }
}
