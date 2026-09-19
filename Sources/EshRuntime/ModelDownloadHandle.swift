import Foundation
import EshCore

// rc.21 — public download-lifecycle facade over the existing installer. Surfaces the rich `DownloadState`
// (bytes / totalBytes / bytesPerSecond / etaSeconds / currentFile / phase) instead of a bare Double, and a
// small stable handle with pause / resume / cancel. It wraps the existing `install(onProgress:)` — which
// stays available — so no internal coordinator objects leak.

/// Derives a truthful `DownloadState` from the installer's fractional progress plus the descriptor's known
/// total bytes and a wall-clock throughput estimate (EWMA). Byte counts are real (fraction × known total);
/// throughput/ETA are computed from real samples over real time — never fabricated.
final class DownloadProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let expectedBytes: Int64
    private let fileName: String
    private let clock: @Sendable () -> Date       // injectable for deterministic tests
    private var lastTime: Date?
    private var lastBytes: Int64 = 0
    private var bps: Double?

    init(expectedBytes: Int64, fileName: String, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.expectedBytes = expectedBytes
        self.fileName = fileName
        self.clock = clock
    }

    func state(fraction: Double) -> DownloadState {
        lock.lock(); defer { lock.unlock() }
        let f = min(max(fraction, 0), 1)
        let bytes = expectedBytes > 0 ? Int64(Double(expectedBytes) * f) : 0
        let now = clock()
        if let lt = lastTime {
            let dt = now.timeIntervalSince(lt)
            if dt >= 0.25 {                                   // smooth: sample at most ~4×/s
                let inst = Double(bytes - lastBytes) / dt
                bps = bps.map { $0 * 0.7 + inst * 0.3 } ?? inst   // EWMA
                lastTime = now; lastBytes = bytes
            }
        } else {
            lastTime = now; lastBytes = bytes
        }
        let remaining = max(expectedBytes - bytes, 0)
        let eta: Double? = (bps ?? 0) > 0 ? Double(remaining) / (bps ?? 1) : nil
        return DownloadState(phase: .downloading, bytesDownloaded: bytes,
                             totalBytes: expectedBytes > 0 ? expectedBytes : nil,
                             bytesPerSecond: bps, etaSeconds: eta, currentFile: fileName)
    }
}

/// A stable handle over one model install. `events` streams `DownloadState`; `pause`/`resume`/`cancel`
/// control the transfer. Semantics: **pause** stops but retains the resumable partial; **resume** continues
/// (not restart) where the OS supports it; **cancel** terminates cleanly and discards the partial. Removing
/// an already-installed model stays separate (`EshRuntime.remove`).
public actor ModelDownloadHandle {
    public typealias InstallRun = @Sendable (_ onProgress: @escaping @Sendable (Double) -> Void) async throws -> Void

    public nonisolated let id: String
    public nonisolated let events: AsyncThrowingStream<DownloadState, Error>

    private let expectedBytes: Int64
    private let runInstall: InstallRun               // continues from any retained partial on each call
    private let discardPartial: @Sendable () async -> Void
    private let tracker: DownloadProgressTracker
    private let continuation: AsyncThrowingStream<DownloadState, Error>.Continuation
    private var task: Task<Void, Never>?
    private enum Intent { case running, paused, cancelled, done }
    private var intent: Intent = .running

    /// - Parameters:
    ///   - install: runs (or resumes) the transfer, reporting fractional progress; must honor task
    ///     cancellation by throwing `CancellationError` while retaining the resumable partial.
    ///   - discardPartial: removes the resumable partial (used by `cancel()`).
    init(id: String, expectedBytes: Int64, install: @escaping InstallRun,
         discardPartial: @escaping @Sendable () async -> Void) {
        self.id = id
        self.expectedBytes = expectedBytes
        self.runInstall = install
        self.discardPartial = discardPartial
        self.tracker = DownloadProgressTracker(expectedBytes: expectedBytes, fileName: id)
        var cont: AsyncThrowingStream<DownloadState, Error>.Continuation!
        self.events = AsyncThrowingStream { cont = $0 }
        self.continuation = cont
    }

    func start() { launch(emitResolving: true) }

    private func total() -> Int64? { expectedBytes > 0 ? expectedBytes : nil }

    private func launch(emitResolving: Bool) {
        if emitResolving {
            continuation.yield(DownloadState(phase: .resolving, totalBytes: total(), currentFile: id))
        }
        let cont = continuation, tracker = tracker, run = runInstall
        let fileID = id, bytes = expectedBytes
        task = Task { [weak self] in
            do {
                try await run { p in cont.yield(tracker.state(fraction: p)) }
                cont.yield(DownloadState(phase: .installed, bytesDownloaded: bytes,
                                         totalBytes: bytes > 0 ? bytes : nil, currentFile: fileID))
                await self?.finishSuccessfully()
            } catch is CancellationError {
                await self?.handleCancellation()
            } catch {
                cont.yield(DownloadState(phase: .failed, currentFile: fileID, message: error.localizedDescription))
                await self?.finish(throwing: error)
            }
        }
    }

    private func finishSuccessfully() { intent = .done; continuation.finish() }
    private func finish(throwing error: Error?) { intent = .done; continuation.finish(throwing: error) }

    private func handleCancellation() async {
        switch intent {
        case .paused:
            // Stopped for a pause: retain the partial, keep the stream open for resume().
            continuation.yield(DownloadState(phase: .paused, totalBytes: total(), currentFile: id,
                                             message: "paused; resumable partial retained"))
        case .cancelled:
            await discardPartial()
            continuation.yield(DownloadState(phase: .failed, totalBytes: total(), currentFile: id, message: "cancelled"))
            finish(throwing: CancellationError())
        default:
            finish(throwing: CancellationError())
        }
    }

    // MARK: - Controls

    public func pause() {
        guard intent == .running else { return }
        intent = .paused
        task?.cancel()      // installer persists resume data on cancellation
    }

    public func resume() {
        guard intent == .paused else { return }
        intent = .running
        launch(emitResolving: false)   // install() continues from the retained resume data
    }

    public func cancel() async {
        switch intent {
        case .running:
            intent = .cancelled
            task?.cancel()             // → handleCancellation(.cancelled): discard partial + finish
        case .paused:
            intent = .cancelled        // no task in flight; discard + finish directly
            await discardPartial()
            continuation.yield(DownloadState(phase: .failed, totalBytes: total(), currentFile: id, message: "cancelled"))
            finish(throwing: CancellationError())
        case .cancelled, .done:
            return
        }
    }
}

public extension EshRuntime {
    /// Stream a model install's rich progress (`DownloadState`: bytes, throughput, ETA, currentFile, phase)
    /// instead of a bare fraction. Cancelling the consuming task pauses the transfer (resumable partial is
    /// retained); re-calling continues from it. For explicit pause/resume/cancel controls, use
    /// `installSession(_:)`. The existing `install(_:onProgress:)` remains available and unchanged.
    nonisolated func installStream(_ descriptor: LocalModelDescriptor) -> AsyncThrowingStream<DownloadState, Error> {
        let tracker = DownloadProgressTracker(expectedBytes: descriptor.expectedBytes, fileName: descriptor.id)
        let total: Int64? = descriptor.expectedBytes > 0 ? descriptor.expectedBytes : nil
        return AsyncThrowingStream { continuation in
            continuation.yield(DownloadState(phase: .resolving, totalBytes: total, currentFile: descriptor.id))
            let task = Task {
                do {
                    _ = try await self.install(descriptor, onProgress: { p in continuation.yield(tracker.state(fraction: p)) })
                    continuation.yield(DownloadState(phase: .installed, bytesDownloaded: descriptor.expectedBytes,
                                                     totalBytes: total, currentFile: descriptor.id))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(DownloadState(phase: .paused, totalBytes: total, currentFile: descriptor.id,
                                                     message: "paused; resumable partial retained"))
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.yield(DownloadState(phase: .failed, totalBytes: total, currentFile: descriptor.id,
                                                     message: error.localizedDescription))
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Begin a model install and return a controllable session (rich `events` stream + pause/resume/cancel).
    func installSession(_ descriptor: LocalModelDescriptor) -> ModelDownloadHandle {
        let manager = localModelManagerRef()
        let handle = ModelDownloadHandle(
            id: descriptor.id, expectedBytes: descriptor.expectedBytes,
            install: { onProgress in _ = try await manager.install(descriptor, onProgress: onProgress) },
            discardPartial: { await manager.discardPartialDownload(descriptor.id) })
        Task { await handle.start() }
        return handle
    }
}
