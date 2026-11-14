import Foundation
import Network

/// A tiny deterministic HTTP server for download tests (no external network).
///
/// Two properties matter on CI (3-core macOS runners) and are why this exists instead of an inline helper:
///
/// 1. It binds to the loopback interface only (127.0.0.1). A listener on all interfaces is subject to macOS
///    Local Network privacy; on a headless runner nobody can answer that prompt, so the listener never reaches
///    `.ready`. Loopback is exempt.
/// 2. Readiness is awaited asynchronously with a bound. The previous helpers blocked a Swift-concurrency
///    cooperative thread on `DispatchSemaphore.wait()` until `.ready`. Three such tests occupy all three
///    cooperative threads of a CI runner, which starves every other test in the process: `swift test` hung
///    until the job timeout with ~500 tests "started" and none finished.
final class LoopbackHTTPServer: @unchecked Sendable {
    struct NotReady: Error, CustomStringConvertible {
        let description: String
    }

    private let listener: NWListener
    let port: UInt16

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    /// Starts serving `body` to every request. `contentLengthOverride` advertises a different Content-Length
    /// (to force a size mismatch); `responseDelayMs` delays each response without blocking any thread.
    static func start(body: Data, contentLengthOverride: Int? = nil, responseDelayMs: Int = 0,
                      readinessTimeout: TimeInterval = 10) async throws -> LoopbackHTTPServer {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        let queue = DispatchQueue(label: "esh.tests.loopback-http")

        listener.newConnectionHandler = { conn in
            conn.start(queue: queue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                let len = contentLengthOverride ?? body.count
                let header = "HTTP/1.1 200 OK\r\nContent-Length: \(len)\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n"
                var out = Data(header.utf8); out.append(body)
                queue.asyncAfter(deadline: .now() + .milliseconds(responseDelayMs)) {
                    conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
                }
            }
        }

        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            listener.stateUpdateHandler = { state in
                once.lastState = "\(state)"
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue { once.resume(returning: port) }
                    else { once.resume(throwing: NotReady(description: "listener ready without a port")) }
                case .failed(let error):
                    once.resume(throwing: NotReady(description: "listener failed: \(error)"))
                    listener.cancel()
                case .cancelled:
                    once.resume(throwing: NotReady(description: "listener cancelled before ready"))
                default:
                    break   // .setup / .waiting: keep waiting until ready, failed, or the timeout below
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + readinessTimeout) {
                once.resume(throwing: NotReady(
                    description: "listener not ready after \(readinessTimeout)s (last state: \(once.lastState))"))
                listener.cancel()   // no-op once ready and owned by the returned server's stop()
            }
        }
        return LoopbackHTTPServer(listener: listener, port: port)
    }

    func url(path: String = "/model.gguf") -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
    func stop() { listener.cancel() }
}

/// Resumes a continuation exactly once; later calls are ignored. Accessed only on the listener's serial queue.
private final class ResumeOnce: @unchecked Sendable {
    private var continuation: CheckedContinuation<UInt16, Error>?
    var lastState = "setup"

    init(_ continuation: CheckedContinuation<UInt16, Error>) { self.continuation = continuation }

    func resume(returning port: UInt16) {
        continuation?.resume(returning: port); continuation = nil
    }

    func resume(throwing error: Error) {
        continuation?.resume(throwing: error); continuation = nil
    }
}
