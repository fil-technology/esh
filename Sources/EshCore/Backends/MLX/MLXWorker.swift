import Foundation

/// One line the persistent MLX worker (`mlx-serve`) emits on stdout.
struct MLXWorkerLine: Decodable, Sendable {
    var id: String?
    var event: String
    var text: String?
    var metrics: Metrics?
    var message: String?
    var loadMs: Double?
    var memoryBytes: Int64?
    var model: String?
}

/// A decoded worker event routed to a caller.
enum MLXWorkerEvent: Sendable {
    case token(String)
    case done(Metrics?)
}

enum MLXWorkerError: Error, LocalizedError {
    case startupFailed(String)
    case crashed(String)
    case notReady
    var errorDescription: String? {
        switch self {
        case let .startupFailed(m): return "MLX worker failed to start: \(m)"
        case let .crashed(m): return "MLX worker exited unexpectedly: \(m)"
        case .notReady: return "MLX worker is not ready."
        }
    }
}

/// Owns ONE long-lived `mlx-serve` Python process that loads a single model once and serves many
/// requests over a newline-delimited JSON protocol — giving true weights residency. Backend/protocol
/// detail is hidden behind this type; `PersistentMLXRuntime` (a `BackendRuntime`) is the only caller.
///
/// Lifetime is owned by whoever holds the runtime — in production that is `RuntimeLifecycleManager`,
/// which calls `unload()` on eviction. The worker also exits on its own if esh dies (its stdin
/// closes → EOF), so no orphan Python processes survive the parent.
final class MLXWorkerProcess: @unchecked Sendable {
    struct ReadyInfo: Sendable {
        var loadMilliseconds: Double
        var memoryBytes: Int64?
    }

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    private let lock = NSLock()
    private var streams: [String: AsyncThrowingStream<MLXWorkerEvent, Error>.Continuation] = [:]
    private var readyContinuation: CheckedContinuation<ReadyInfo, Error>?
    private var terminated = false
    private var stderrTail = ""
    private var stdoutBuffer = Data()
    private(set) var readyInfo: ReadyInfo?

    var isAlive: Bool {
        lock.lock(); defer { lock.unlock() }
        return !terminated
    }

    private static let debug = ProcessInfo.processInfo.environment["ESH_MLX_WORKER_DEBUG"] == "1"
    private static func trace(_ message: @autoclosure () -> String) {
        guard debug else { return }
        FileHandle.standardError.write(Data(("[mlxworker] " + message() + "\n").utf8))
    }

    func start(pythonURL: URL, bridgeScriptURL: URL, modelPath: String, modelID: String) async throws {
        process.executableURL = pythonURL
        process.arguments = [bridgeScriptURL.path, "mlx-serve"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Collect stderr for crash diagnostics.
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            self.lock.lock()
            self.stderrTail = String(String(decoding: data, as: UTF8.self).suffix(2000))
            self.lock.unlock()
        }

        process.terminationHandler = { [weak self] proc in
            self?.handleTermination(status: proc.terminationStatus)
        }

        // Robust line reader for a long-lived duplex process: accumulate stdout and split on newlines
        // as data arrives (FileHandle.bytes.lines can buffer small lines until EOF, which never comes
        // for a persistent worker).
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.consumeStdout(data)
        }

        try process.run()
        Self.trace("spawned pid=\(process.processIdentifier)")

        // Send the init line and await the `ready` event (or a startup error / crash).
        let initLine = try Self.jsonLine(["op": "init", "modelPath": modelPath, "modelID": modelID])
        try writeLine(initLine)

        // Guard against a wedged startup: if `ready` never arrives, fail loudly instead of hanging.
        let timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180 * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.resumeReady(.failure(MLXWorkerError.startupFailed("timed out waiting for model load")))
        }
        defer { timeout.cancel() }

        let info = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ReadyInfo, Error>) in
            lock.lock()
            if terminated {
                lock.unlock()
                cont.resume(throwing: MLXWorkerError.startupFailed(stderrSnapshot()))
                return
            }
            readyContinuation = cont
            lock.unlock()
        }
        setReadyInfo(info)
    }

    private func setReadyInfo(_ info: ReadyInfo) {
        lock.lock(); readyInfo = info; lock.unlock()
    }

    /// Stream one generation. Cancelling the returned stream sends a cancel message to the worker.
    func generate(requestJSON: Data) -> AsyncThrowingStream<MLXWorkerEvent, Error> {
        let id = UUID().uuidString
        return AsyncThrowingStream { continuation in
            lock.lock()
            if terminated {
                lock.unlock()
                continuation.finish(throwing: MLXWorkerError.crashed(stderrSnapshot()))
                return
            }
            streams[id] = continuation
            lock.unlock()

            // Envelope: {"id":..., "op":"generate", "request": <request>}
            var envelope = Data(#"{"id":"#.utf8)
            envelope.append(Data("\"\(id)\",\"op\":\"generate\",\"request\":".utf8))
            envelope.append(requestJSON)
            envelope.append(Data("}\n".utf8))
            do {
                try writeData(envelope)
            } catch {
                finish(id: id, throwing: error)
                return
            }

            continuation.onTermination = { [weak self] reason in
                guard let self else { return }
                // If the consumer cancelled early, tell the worker to stop generating.
                if case .cancelled = reason {
                    try? self.writeLine(Self.jsonLineOrEmpty(["id": id, "op": "cancel"]))
                }
                self.lock.lock(); self.streams[id] = nil; self.lock.unlock()
            }
        }
    }

    func ping() -> Bool {
        (try? writeLine(Self.jsonLineOrEmpty(["op": "ping"]))) != nil && isAlive
    }

    /// Graceful shutdown: ask the worker to stop, then terminate if it lingers.
    func shutdown() {
        try? writeLine(Self.jsonLineOrEmpty(["op": "shutdown"]))
        try? stdinPipe.fileHandleForWriting.close()
        // Give it a brief chance to exit on its own, then force.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            if self.process.isRunning { self.process.terminate() }
        }
    }

    // MARK: - Internals

    private func consumeStdout(_ data: Data) {
        lock.lock()
        stdoutBuffer.append(data)
        var lines: [Data] = []
        let newline: UInt8 = 0x0A
        while let index = stdoutBuffer.firstIndex(of: newline) {
            let line = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<index)
            lines.append(line)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...index)
        }
        lock.unlock()
        for line in lines { handleLineData(line) }
    }

    private func handleLineData(_ data: Data) {
        guard !data.isEmpty else { return }
        guard let parsed = try? JSONCoding.decoder.decode(MLXWorkerLine.self, from: data) else {
            Self.trace("undecodable line: \(String(decoding: data.prefix(200), as: UTF8.self))")
            return
        }
        Self.trace("line id=\(parsed.id ?? "-") event=\(parsed.event)")

        if let id = parsed.id {
            switch parsed.event {
            case "token":
                if let text = parsed.text { yield(id: id, .token(text)) }
            case "done":
                yield(id: id, .done(parsed.metrics))
                finish(id: id, throwing: nil)
            case "error":
                finish(id: id, throwing: MLXWorkerError.crashed(parsed.message ?? "worker error"))
            default:
                break
            }
            return
        }

        switch parsed.event {
        case "ready":
            resumeReady(.success(ReadyInfo(loadMilliseconds: parsed.loadMs ?? 0, memoryBytes: parsed.memoryBytes)))
        case "error":
            resumeReady(.failure(MLXWorkerError.startupFailed(parsed.message ?? "unknown")))
        default:
            break
        }
    }

    private func handleTermination(status: Int32) {
        lock.lock()
        terminated = true
        let pendingStreams = streams
        streams.removeAll()
        let ready = readyContinuation
        readyContinuation = nil
        let tail = stderrTail
        lock.unlock()

        let error = MLXWorkerError.crashed(tail.isEmpty ? "exit status \(status)" : tail)
        for (_, cont) in pendingStreams { cont.finish(throwing: error) }
        ready?.resume(throwing: MLXWorkerError.startupFailed(tail.isEmpty ? "exit status \(status)" : tail))
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
    }

    private func yield(id: String, _ event: MLXWorkerEvent) {
        lock.lock(); let cont = streams[id]; lock.unlock()
        cont?.yield(event)
    }

    private func finish(id: String, throwing error: Error?) {
        lock.lock(); let cont = streams[id]; streams[id] = nil; lock.unlock()
        if let error { cont?.finish(throwing: error) } else { cont?.finish() }
    }

    private func resumeReady(_ result: Result<ReadyInfo, Error>) {
        lock.lock(); let cont = readyContinuation; readyContinuation = nil; lock.unlock()
        cont?.resume(with: result)
    }

    private func stderrSnapshot() -> String {
        lock.lock(); defer { lock.unlock() }
        return stderrTail
    }

    private func writeLine(_ line: String) throws {
        try writeData(Data((line + "\n").utf8))
    }

    private func writeData(_ data: Data) throws {
        lock.lock(); let dead = terminated; lock.unlock()
        if dead { throw MLXWorkerError.crashed(stderrSnapshot()) }
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    private static func jsonLine(_ dict: [String: String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: dict)
        return String(decoding: data, as: UTF8.self)
    }

    private static func jsonLineOrEmpty(_ dict: [String: String]) -> String {
        (try? jsonLine(dict)) ?? "{}"
    }
}
