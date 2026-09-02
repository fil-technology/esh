import Foundation

/// A persistent `llama-server` subprocess for one GGUF model.
///
/// Why this exists: esh used to spawn `llama-completion` per request with a hand-built
/// `User:/Assistant:` transcript. That is NOT the model's chat format, so the model never emitted its
/// native end-of-turn token and ran away generating a hallucinated multi-turn transcript until the
/// token limit. `llama-server --jinja` instead applies the model's OWN embedded chat template
/// (`tokenizer.chat_template`) and stops at the model's native assistant-turn end — no esh-side,
/// model-family-specific prompt strings. It is the supported non-interactive chat surface and gives us
/// multi-turn history, EOS/stop, streaming, cancellation, JSON-schema/grammar and caller stop
/// sequences in one place, over an OpenAI-compatible endpoint.
///
/// One model per server; the process stays resident for the runtime's lifetime (owned by
/// `RuntimeLifecycleManager`), so the model is loaded once — true weights residency.
final class LlamaServerProcess: @unchecked Sendable {
    let port: Int
    private let process = Process()
    private let baseURL: URL
    private let urlSession: URLSession
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var alive = false
    private var stderrTail = Data()
    private(set) var loadMilliseconds: Double = 0

    var isAlive: Bool { lock.lock(); defer { lock.unlock() }; return alive && process.isRunning }
    private func setAlive(_ value: Bool) { lock.lock(); alive = value; lock.unlock() }

    init(executableURL: URL, modelPath: String, contextLength: Int = 8192, gpuLayers: Int = 999) throws {
        self.port = try Self.reserveFreePort()
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 600
        cfg.timeoutIntervalForResource = 3600
        cfg.waitsForConnectivity = false
        self.urlSession = URLSession(configuration: cfg)

        process.executableURL = executableURL
        process.arguments = [
            "-m", modelPath,
            "--host", "127.0.0.1",
            "--port", String(port),
            "-c", String(contextLength),
            "-ngl", String(gpuLayers),
            "--jinja",                       // apply the model's OWN embedded chat template
            "--reasoning-format", "none",    // keep <think> tags inline in content (esh parses them)
            "--no-webui",
            "-np", "1"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        // Drain stderr into a small capped tail so a full pipe never blocks the server, while still
        // surfacing the last lines if startup fails.
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.lock()
            self.stderrTail.append(data)
            if self.stderrTail.count > 8192 { self.stderrTail.removeFirst(self.stderrTail.count - 8192) }
            self.lock.unlock()
        }
    }

    /// Launch the server and wait until it reports healthy (model loaded).
    func start(readyTimeout: TimeInterval = 180) async throws {
        let t0 = Date()
        try process.run()
        let start = Date()
        while Date().timeIntervalSince(start) < readyTimeout {
            if !process.isRunning {
                throw StoreError.invalidManifest("llama-server exited during startup.\n\(recentStderr())")
            }
            if await isHealthy() {
                loadMilliseconds = Date().timeIntervalSince(t0) * 1000
                setAlive(true)
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        shutdown()
        throw StoreError.invalidManifest("llama-server did not become ready within \(Int(readyTimeout))s.\n\(recentStderr())")
    }

    private func isHealthy() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("health"))
        req.timeoutInterval = 3
        guard let (_, resp) = try? await urlSession.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    private func recentStderr() -> String {
        lock.lock(); let d = stderrTail; lock.unlock()
        return String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stream assistant content deltas from `/v1/chat/completions` (SSE). `body` is the fully-formed
    /// OpenAI chat-completions request JSON (with `stream: true`).
    func generate(body: Data) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.httpBody = body
                    let (bytes, resp) = try await urlSession.bytes(for: req)
                    let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
                    guard status == 200 else {
                        var errText = ""
                        for try await line in bytes.lines { errText += line; if errText.count > 2000 { break } }
                        throw StoreError.invalidManifest("llama-server returned HTTP \(status): \(errText)")
                    }
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8) else { continue }
                        if let delta = Self.contentDelta(from: data), !delta.isEmpty {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled { continuation.finish() }
                    else { continuation.finish(throwing: error) }
                }
            }
            continuation.onTermination = { reason in
                if case .cancelled = reason { task.cancel() }
            }
        }
    }

    /// Extract `choices[0].delta.content` from one SSE chunk.
    static func contentDelta(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any],
              let content = delta["content"] as? String else { return nil }
        return content
    }

    func shutdown() {
        setAlive(false)
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    /// Ask the kernel for an unused TCP port by binding to :0, then release it for llama-server to take.
    /// (Small race window, acceptable for a localhost dev/inference server.)
    private static func reserveFreePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StoreError.invalidManifest("Could not allocate a socket for llama-server.") }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw StoreError.invalidManifest("Could not reserve a port for llama-server.") }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard got == 0 else { throw StoreError.invalidManifest("Could not read the reserved llama-server port.") }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}
