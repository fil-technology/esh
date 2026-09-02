import Foundation

/// One line of the persistent speech worker's stdout protocol (see `speech-serve` in the MLX bridge).
struct SpeechWorkerLine: Decodable, Sendable {
    let event: String
    let id: String?
    let text: String?
    let message: String?
    let loadMs: Double?
    let memoryBytes: Int64?
    let ms: Double?
}

enum SpeechWorkerError: Error, LocalizedError {
    case startupFailed(String)
    case crashed(String)
    case transcription(String)

    var errorDescription: String? {
        switch self {
        case let .startupFailed(m): return "Speech worker failed to start: \(m)"
        case let .crashed(m): return "Speech worker exited unexpectedly: \(m)"
        case let .transcription(m): return "Transcription failed: \(m)"
        }
    }
}

/// A persistent STT worker process (M12). Loads the speech-to-text model ONCE (`speech-serve`) and
/// serves many `transcribe` requests over stdio, so warm transcription no longer pays the per-call
/// Python + model reload that made one-shot `mlx-transcribe` cost several seconds every call.
///
/// Mirrors `MLXWorkerProcess` but STT is request/response (single result per request), not a token
/// stream. `SpeechRuntimeManager` owns the lifetime; stdin EOF (parent death) ends the worker so no
/// orphan survives esh.
final class SpeechWorkerProcess: @unchecked Sendable {
    struct ReadyInfo: Sendable {
        let loadMilliseconds: Double
        let memoryBytes: Int64?
    }

    let modelPath: String
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    private let lock = NSLock()
    private var pending: [String: CheckedContinuation<String, Error>] = [:]
    private var readyContinuation: CheckedContinuation<ReadyInfo, Error>?
    private var terminated = false
    private var stderrTail = ""
    private var stdoutBuffer = Data()
    private(set) var readyInfo: ReadyInfo?

    var isAlive: Bool {
        lock.lock(); defer { lock.unlock() }
        return !terminated && process.isRunning
    }

    init(modelPath: String) { self.modelPath = modelPath }

    func start(pythonURL: URL, bridgeScriptURL: URL, modelID: String, readyTimeout: TimeInterval = 180) async throws {
        process.executableURL = pythonURL
        process.arguments = [bridgeScriptURL.path, "speech-serve"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            self.lock.lock()
            self.stderrTail = String(String(decoding: data, as: UTF8.self).suffix(2000))
            self.lock.unlock()
        }
        process.terminationHandler = { [weak self] proc in self?.handleTermination(status: proc.terminationStatus) }
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self.consumeStdout(data)
        }

        try process.run()
        try writeLine(Self.jsonLine(["op": "init", "modelPath": modelPath, "modelID": modelID]))

        let timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(readyTimeout) * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.resumeReady(.failure(SpeechWorkerError.startupFailed("timed out waiting for STT model load")))
        }
        defer { timeout.cancel() }

        let info = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ReadyInfo, Error>) in
            lock.lock()
            if terminated { lock.unlock(); cont.resume(throwing: SpeechWorkerError.startupFailed(stderrSnapshot())); return }
            readyContinuation = cont
            lock.unlock()
        }
        setReadyInfo(info)
    }

    private func setReadyInfo(_ info: ReadyInfo) { lock.lock(); readyInfo = info; lock.unlock() }

    var loadMilliseconds: Double { readyInfo?.loadMilliseconds ?? 0 }
    var memoryBytes: Int64? { readyInfo?.memoryBytes }

    /// Transcribe one audio file on the already-loaded model.
    func transcribe(audioPath: String, language: String?) async throws -> String {
        let id = UUID().uuidString
        var request: [String: String] = ["id": id, "op": "transcribe", "audioPath": audioPath]
        if let language, !language.isEmpty { request["language"] = language }
        let line = try Self.jsonLine(request)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            lock.lock()
            if terminated { lock.unlock(); cont.resume(throwing: SpeechWorkerError.crashed(stderrSnapshot())); return }
            pending[id] = cont
            lock.unlock()
            do { try writeLine(line) } catch {
                lock.lock(); pending[id] = nil; lock.unlock()
                cont.resume(throwing: error)
            }
        }
    }

    func ping() -> Bool { (try? writeLine(Self.jsonLine(["op": "ping"]))) != nil && isAlive }

    func shutdown() {
        try? writeLine(Self.jsonLine(["op": "shutdown"]))
        try? stdinPipe.fileHandleForWriting.close()
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
            lines.append(stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<index))
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...index)
        }
        lock.unlock()
        for line in lines { handleLineData(line) }
    }

    private func handleLineData(_ data: Data) {
        guard !data.isEmpty,
              let parsed = try? JSONCoding.decoder.decode(SpeechWorkerLine.self, from: data) else { return }
        if let id = parsed.id {
            switch parsed.event {
            case "result": resume(id: id, .success(parsed.text ?? ""))
            case "error": resume(id: id, .failure(SpeechWorkerError.transcription(parsed.message ?? "unknown")))
            default: break
            }
            return
        }
        switch parsed.event {
        case "ready": resumeReady(.success(ReadyInfo(loadMilliseconds: parsed.loadMs ?? 0, memoryBytes: parsed.memoryBytes)))
        case "error": resumeReady(.failure(SpeechWorkerError.startupFailed(parsed.message ?? "unknown")))
        default: break
        }
    }

    private func handleTermination(status: Int32) {
        lock.lock()
        terminated = true
        let pendingRequests = pending; pending.removeAll()
        let ready = readyContinuation; readyContinuation = nil
        let tail = stderrTail
        lock.unlock()
        let detail = tail.isEmpty ? "exit status \(status)" : tail
        for (_, cont) in pendingRequests { cont.resume(throwing: SpeechWorkerError.crashed(detail)) }
        ready?.resume(throwing: SpeechWorkerError.startupFailed(detail))
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
    }

    private func resume(id: String, _ result: Result<String, Error>) {
        lock.lock(); let cont = pending[id]; pending[id] = nil; lock.unlock()
        cont?.resume(with: result)
    }

    private func resumeReady(_ result: Result<ReadyInfo, Error>) {
        lock.lock(); let cont = readyContinuation; readyContinuation = nil; lock.unlock()
        cont?.resume(with: result)
    }

    private func stderrSnapshot() -> String { lock.lock(); defer { lock.unlock() }; return stderrTail }

    private func writeLine(_ line: String) throws {
        lock.lock(); let dead = terminated; lock.unlock()
        if dead { throw SpeechWorkerError.crashed(stderrSnapshot()) }
        try stdinPipe.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    private static func jsonLine(_ dict: [String: String]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: dict), as: UTF8.self)
    }
}
