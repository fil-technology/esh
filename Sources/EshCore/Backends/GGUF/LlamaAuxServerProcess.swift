import Foundation

// esh 2.1 UCMR, Stage 1b — a llama-server run in an auxiliary mode (embeddings or reranking). Reuses the
// already-bundled static llama-server (MIT) with --embeddings / --reranking, so esh gains embed + rerank
// capabilities with ZERO new runtime dependency and no GPL (unlike mlx-embeddings). One model per server.

final class LlamaAuxServerProcess: @unchecked Sendable {
    enum Mode: Sendable { case embeddings, reranking }

    struct RankResult: Sendable, Equatable { let index: Int; let score: Double }

    let port: Int
    let mode: Mode
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

    init(executableURL: URL, modelPath: String, mode: Mode, contextLength: Int = 8192, gpuLayers: Int = 999) throws {
        self.mode = mode
        self.port = try Self.reserveFreePort()
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 300
        cfg.waitsForConnectivity = false
        self.urlSession = URLSession(configuration: cfg)

        var args = [
            "-m", modelPath,
            "--host", "127.0.0.1",
            "--port", String(port),
            "-c", String(contextLength),
            "-ngl", String(gpuLayers),
            "--no-webui",
            "-np", "1"
        ]
        switch mode {
        case .embeddings: args += ["--embeddings", "--pooling", "mean"]
        case .reranking: args += ["--reranking"]
        }
        process.executableURL = executableURL
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.lock()
            self.stderrTail.append(data)
            if self.stderrTail.count > 8192 { self.stderrTail.removeFirst(self.stderrTail.count - 8192) }
            self.lock.unlock()
        }
    }

    func start(readyTimeout: TimeInterval = 180) async throws {
        let t0 = Date()
        try process.run()
        let start = Date()
        while Date().timeIntervalSince(start) < readyTimeout {
            if !process.isRunning {
                throw StoreError.invalidManifest("llama-server (\(modeName)) exited during startup.\n\(recentStderr())")
            }
            if await isHealthy() {
                loadMilliseconds = Date().timeIntervalSince(t0) * 1000
                setAlive(true)
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        shutdown()
        throw StoreError.invalidManifest("llama-server (\(modeName)) did not become ready within \(Int(readyTimeout))s.\n\(recentStderr())")
    }

    private var modeName: String { mode == .embeddings ? "embeddings" : "reranking" }

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

    /// POST /v1/embeddings {"input": texts} → one vector per input (order preserved).
    func embed(_ texts: [String]) async throws -> [[Float]] {
        let body = try JSONSerialization.data(withJSONObject: ["input": texts])
        let data = try await post("v1/embeddings", body: body)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["data"] as? [[String: Any]] else {
            throw StoreError.invalidManifest("Unexpected /v1/embeddings response.")
        }
        // Preserve input order via each row's "index" when present.
        let ordered = rows.sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }
        return ordered.map { row in
            (row["embedding"] as? [Any])?.compactMap { ($0 as? NSNumber)?.floatValue } ?? []
        }
    }

    /// POST /rerank {"query":…, "documents":[…]} → (index, score) per document.
    func rerank(query: String, documents: [String]) async throws -> [RankResult] {
        let body = try JSONSerialization.data(withJSONObject: ["query": query, "documents": documents])
        let data = try await post("rerank", body: body)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["results"] as? [[String: Any]] else {
            throw StoreError.invalidManifest("Unexpected /rerank response.")
        }
        return rows.compactMap { row in
            guard let idx = row["index"] as? Int else { return nil }
            let score = (row["relevance_score"] as? NSNumber)?.doubleValue ?? (row["score"] as? NSNumber)?.doubleValue ?? 0
            return RankResult(index: idx, score: score)
        }
    }

    private func post(_ path: String, body: Data) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, resp) = try await urlSession.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw StoreError.invalidManifest("llama-server (\(modeName)) HTTP \(status): \(String(decoding: data, as: UTF8.self).prefix(400))")
        }
        return data
    }

    func shutdown() {
        setAlive(false)
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

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
