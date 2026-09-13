import Foundation

// esh M8 — efficient, resumable file download with progress. Wraps URLSessionDownloadTask (native,
// fast — not byte-by-byte) behind async/await, reports progress via a callback, persists resume data on
// cancellation/failure, and hands back the downloaded temp file for verification before finalize.

public struct DownloadOutcome: Sendable {
    public let tempURL: URL          // caller must move/consume this
    public let httpStatus: Int
    public let expectedBytes: Int64
}

final class ResumableDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var onProgress: (@Sendable (Double) -> Void)?
    private var continuation: CheckedContinuation<DownloadOutcome, Error>?
    private var stagedURL: URL?
    private var httpStatus: Int = 0
    private var expected: Int64 = 0
    /// Where to persist resume data if the download is interrupted (nil = don't persist).
    private let resumeDataURL: URL?
    private lazy var session: URLSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    init(resumeDataURL: URL?) { self.resumeDataURL = resumeDataURL }

    /// Download `request` fresh, or resume from `resumeData` if provided. Deletes any persisted resume
    /// data on success. Cancelling the surrounding Task cancels the download and persists resume data.
    func run(request: URLRequest, resumeData: Data?, onProgress: @escaping @Sendable (Double) -> Void) async throws -> DownloadOutcome {
        self.onProgress = onProgress
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<DownloadOutcome, Error>) in
                self.continuation = cont
                let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: request)
                self.currentTask = task
                task.resume()
            }
        } onCancel: {
            self.currentTask?.cancel(byProducingResumeData: { data in
                if let data, let url = self.resumeDataURL { try? data.write(to: url) }
            })
        }
    }

    private var currentTask: URLSessionDownloadTask?

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            onProgress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        httpStatus = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        expected = downloadTask.countOfBytesExpectedToReceive
        // The delegate's temp file is deleted when this method returns — move it somewhere stable now.
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("esh-dl-\(UUID().uuidString)")
        do { try FileManager.default.moveItem(at: location, to: staged); stagedURL = staged }
        catch { stagedURL = nil }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { self.session.invalidateAndCancel() }
        if let error {
            let nsError = error as NSError
            if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, let url = resumeDataURL {
                try? data.write(to: url)
            }
            if nsError.code == NSURLErrorCancelled {
                continuation?.resume(throwing: CancellationError())
            } else {
                continuation?.resume(throwing: error)
            }
            continuation = nil
            return
        }
        guard let staged = stagedURL else {
            continuation?.resume(throwing: LocalModelError.downloadFailed("no downloaded file produced"))
            continuation = nil; return
        }
        if let url = resumeDataURL { try? FileManager.default.removeItem(at: url) }   // success → clear resume data
        continuation?.resume(returning: DownloadOutcome(tempURL: staged, httpStatus: httpStatus, expectedBytes: expected))
        continuation = nil
    }
}
