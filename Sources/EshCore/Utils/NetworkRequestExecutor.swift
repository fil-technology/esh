import Foundation

public struct NetworkRetryPolicy: Sendable {
    public var requestTimeout: TimeInterval
    public var maxAttempts: Int
    public var baseDelayMilliseconds: UInt64

    public init(
        requestTimeout: TimeInterval = 30,
        maxAttempts: Int = 3,
        baseDelayMilliseconds: UInt64 = 500
    ) {
        self.requestTimeout = requestTimeout
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelayMilliseconds = baseDelayMilliseconds
    }

    public static let `default` = NetworkRetryPolicy()

    fileprivate func delayNanoseconds(forAttempt attempt: Int) -> UInt64 {
        let multiplier = UInt64(1 << max(0, attempt - 1))
        return baseDelayMilliseconds * multiplier * 1_000_000
    }

    fileprivate func isRetryable(statusCode: Int) -> Bool {
        switch statusCode {
        case 408, 425, 429, 500, 502, 503, 504:
            true
        default:
            false
        }
    }

    fileprivate func isRetryable(error: Error) -> Bool {
        guard let error = error as? URLError else {
            return false
        }

        switch error.code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .resourceUnavailable:
            return true
        default:
            return false
        }
    }
}

/// URLSession data-task delegate that surfaces the response and streams the body as whole `Data` blocks
/// (16 KB–1 MB each) instead of one `UInt8` per async iteration. Bridges the delegate callbacks into an
/// `AsyncThrowingStream<Data, Error>`. NSLock-guarded so its state is safe across the delegate queue and the
/// awaiting task. Holds its session + task strongly during the transfer and tears them down on `cancel()`.
private final class ChunkedDownloadReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var responseContinuation: CheckedContinuation<URLResponse, Error>?
    private var pendingResponse: URLResponse?
    private var pendingError: Error?
    private var responded = false
    private var dataContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var task: URLSessionTask?
    private var session: URLSession?
    private var torndown = false

    func attach(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        lock.lock(); dataContinuation = continuation; lock.unlock()
    }
    func bind(task: URLSessionTask, session: URLSession) {
        lock.lock(); self.task = task; self.session = session; lock.unlock()
    }
    /// Await the initial response (or the failure that preceded it).
    func awaitResponse() async throws -> URLResponse {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if let r = pendingResponse { pendingResponse = nil; lock.unlock(); cont.resume(returning: r); return }
            if let e = pendingError { pendingError = nil; lock.unlock(); cont.resume(throwing: e); return }
            responseContinuation = cont; lock.unlock()
        }
    }
    /// Stop the transfer and break the session↔delegate retain cycle. Idempotent.
    func cancel() {
        lock.lock()
        if torndown { lock.unlock(); return }
        torndown = true
        let t = task; let s = session; task = nil; session = nil
        lock.unlock()
        t?.cancel()
        s?.finishTasksAndInvalidate()
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        responded = true
        let cont = responseContinuation; responseContinuation = nil
        if cont == nil { pendingResponse = response }
        lock.unlock()
        cont?.resume(returning: response)
        completionHandler(.allow)
    }
    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); let c = dataContinuation; lock.unlock()
        c?.yield(data)
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let rc = responseContinuation; responseContinuation = nil
        let dc = dataContinuation; dataContinuation = nil
        let hadResponse = responded
        if let error, !hadResponse, rc == nil { pendingError = error }
        lock.unlock()
        if let error {
            if !hadResponse { rc?.resume(throwing: error) }
            dc?.finish(throwing: error)
        } else {
            dc?.finish()
        }
    }
}

public enum NetworkRequestExecutor {
    /// Establish a **block-delivering** download stream for `request`, applying the same connection-phase
    /// retry policy as `bytes(_:)` (retry on a retryable status / transient error before any body arrives).
    /// Returns the response, an `AsyncThrowingStream` of `Data` blocks, and a `cancel` that stops the transfer
    /// and tears the session down (used by the 416 restart path). Consuming-task cancellation and normal
    /// completion both tear the session down via the stream's `onTermination`, so a cancelled download stops
    /// the underlying transfer (preserving the partial on disk) just as `URLSession.AsyncBytes` did.
    static func dataStream(
        session: URLSession,
        request original: URLRequest,
        retryPolicy: NetworkRetryPolicy = .default
    ) async throws -> (response: URLResponse, stream: AsyncThrowingStream<Data, Error>, cancel: @Sendable () -> Void) {
        var request = original
        request.timeoutInterval = retryPolicy.requestTimeout
        var lastError: Error = URLError(.unknown)
        for attempt in 1...retryPolicy.maxAttempts {
            let reader = ChunkedDownloadReader()
            let delegateSession = URLSession(configuration: session.configuration, delegate: reader, delegateQueue: nil)
            let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
            reader.attach(continuation: continuation)
            let task = delegateSession.dataTask(with: request)
            reader.bind(task: task, session: delegateSession)
            continuation.onTermination = { [reader] _ in reader.cancel() }   // consumer-stop / finish → cancel + invalidate
            task.resume()
            do {
                let response = try await reader.awaitResponse()
                if let http = response as? HTTPURLResponse,
                   retryPolicy.isRetryable(statusCode: http.statusCode), attempt < retryPolicy.maxAttempts {
                    reader.cancel(); continuation.finish()
                    try await Task.sleep(nanoseconds: retryPolicy.delayNanoseconds(forAttempt: attempt))
                    continue
                }
                return (response, stream, { reader.cancel() })
            } catch {
                lastError = error
                reader.cancel(); continuation.finish(throwing: error)
                guard retryPolicy.isRetryable(error: error), attempt < retryPolicy.maxAttempts else { throw error }
                try await Task.sleep(nanoseconds: retryPolicy.delayNanoseconds(forAttempt: attempt))
            }
        }
        throw lastError
    }

    public static func data(
        session: URLSession,
        request: URLRequest,
        retryPolicy: NetworkRetryPolicy = .default
    ) async throws -> (Data, URLResponse) {
        var request = request
        request.timeoutInterval = retryPolicy.requestTimeout

        for attempt in 1...retryPolicy.maxAttempts {
            do {
                let result = try await session.data(for: request)
                if let http = result.1 as? HTTPURLResponse,
                   retryPolicy.isRetryable(statusCode: http.statusCode),
                   attempt < retryPolicy.maxAttempts {
                    try await Task.sleep(nanoseconds: retryPolicy.delayNanoseconds(forAttempt: attempt))
                    continue
                }
                return result
            } catch {
                guard retryPolicy.isRetryable(error: error), attempt < retryPolicy.maxAttempts else {
                    throw error
                }
                try await Task.sleep(nanoseconds: retryPolicy.delayNanoseconds(forAttempt: attempt))
            }
        }

        throw URLError(.unknown)
    }

    public static func bytes(
        session: URLSession,
        request: URLRequest,
        retryPolicy: NetworkRetryPolicy = .default
    ) async throws -> (URLSession.AsyncBytes, URLResponse) {
        var request = request
        request.timeoutInterval = retryPolicy.requestTimeout

        for attempt in 1...retryPolicy.maxAttempts {
            do {
                let result = try await session.bytes(for: request)
                if let http = result.1 as? HTTPURLResponse,
                   retryPolicy.isRetryable(statusCode: http.statusCode),
                   attempt < retryPolicy.maxAttempts {
                    try await Task.sleep(nanoseconds: retryPolicy.delayNanoseconds(forAttempt: attempt))
                    continue
                }
                return result
            } catch {
                guard retryPolicy.isRetryable(error: error), attempt < retryPolicy.maxAttempts else {
                    throw error
                }
                try await Task.sleep(nanoseconds: retryPolicy.delayNanoseconds(forAttempt: attempt))
            }
        }

        throw URLError(.unknown)
    }
}
