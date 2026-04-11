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

public enum NetworkRequestExecutor {
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
