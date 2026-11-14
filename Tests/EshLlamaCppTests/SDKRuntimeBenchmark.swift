import Foundation
import Testing
import EshCore
@testable import EshRuntime
@testable import EshLlamaCpp
#if os(macOS)
import EshMLXText
#endif

// Phase 5 — the public SDK (`EshRuntime`) measured directly, with the same workload `benchmarks/sdk_vs_serve.py` sends
// through `esh serve`. Env-gated: the Python driver sets ESH_SDK_BENCH_* and runs this one test per configuration.
//
//   ESH_SDK_BENCH_HOME       esh store root containing the model (PersistenceRoot)
//   ESH_SDK_BENCH_MODEL      model id to pin
//   ESH_SDK_BENCH_LIFECYCLE  oneShot | managed
//   ESH_SDK_BENCH_SCRIPT     JSON {"long": [...], "concurrent": [[...], ...], "maxTokens": 96, "contextTokens": 8192}
//   ESH_SDK_BENCH_OUT        JSONL file to append the result to

private enum BenchEnv {
    static let env = ProcessInfo.processInfo.environment
    static var enabled: Bool { env["ESH_SDK_BENCH_MODEL"] != nil && env["ESH_SDK_BENCH_SCRIPT"] != nil }
}

private struct Script: Decodable {
    var long: [String]
    var concurrent: [[String]]
    var maxTokens: Int
    var contextTokens: Int
}

/// RSS (GB) of this process plus all of its descendants — the same measure the serve harness uses
/// (`tree_rss_gb`), so in-process (GGUF) and worker-process (MLX) memory compare like for like.
func treeRSSGB() -> Double {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-A", "-o", "pid=,ppid=,rss="]
    let pipe = Pipe(); p.standardOutput = pipe
    try? p.run(); p.waitUntilExit()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    var kids: [Int32: [Int32]] = [:], rss: [Int32: Double] = [:]
    for line in out.split(separator: "\n") {
        let f = line.split(separator: " ", omittingEmptySubsequences: true)
        guard f.count == 3, let pid = Int32(f[0]), let ppid = Int32(f[1]), let kb = Double(f[2]) else { continue }
        kids[ppid, default: []].append(pid); rss[pid] = kb
    }
    var total = 0.0, stack = [getpid()]
    while let pid = stack.popLast() { total += rss[pid] ?? 0; stack += kids[pid] ?? [] }
    return total / 1_048_576
}

func childProcesses() -> [String] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-fl", "-P", String(getpid())]
    let pipe = Pipe(); p.standardOutput = pipe
    try? p.run(); p.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").map(String.init).filter { !$0.contains("pgrep") && !$0.contains("/bin/ps") }
}

private final class PeakSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak = 0.0
    private var running = true
    func start() {
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                let v = treeRSSGB()
                lock.withLock { peak = max(peak, v) }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }
    func stop() -> Double { lock.withLock { running = false; return peak } }
}

private struct TurnResult { var text: String; var ttft: Double?; var e2e: Double; var metrics: Metrics }

private func turn(_ runtime: EshRuntime, model: String, messages: [Message], maxTokens: Int) async throws -> TurnResult {
    let req = EshGenerationRequest(messages: messages, constraints: .pinned(model),
                                   config: GenerationConfig(maxTokens: maxTokens, temperature: 0))
    let t0 = Date()
    var first: Date?
    var text = ""
    var metrics = Metrics()
    for try await event in runtime.stream(req) {
        switch event {
        case let .token(t): if first == nil, !t.isEmpty { first = Date() }; text += t
        case let .completed(r): metrics = r.metrics
        default: break
        }
    }
    return TurnResult(text: text, ttft: first.map { $0.timeIntervalSince(t0) }, e2e: Date().timeIntervalSince(t0), metrics: metrics)
}

private func converse(_ runtime: EshRuntime, model: String, turns: [String], maxTokens: Int) async throws -> [TurnResult] {
    var messages: [Message] = []
    var out: [TurnResult] = []
    for t in turns {
        messages.append(Message(role: .user, text: t))
        let r = try await turn(runtime, model: model, messages: messages, maxTokens: maxTokens)
        messages.append(Message(role: .assistant, text: r.text))
        out.append(r)
    }
    return out
}

private func r2(_ v: Double?) -> Any { v.map { ($0 * 100).rounded() / 100 } ?? NSNull() }

@Suite(.serialized, .enabled(if: BenchEnv.enabled, "set ESH_SDK_BENCH_* (see benchmarks/sdk_vs_serve.py)"))
struct SDKRuntimeBenchmark {
    @Test func sdkSession() async throws {
        let env = BenchEnv.env
        let script = try JSONDecoder().decode(Script.self, from: Data(contentsOf: URL(fileURLWithPath: env["ESH_SDK_BENCH_SCRIPT"]!)))
        let model = env["ESH_SDK_BENCH_MODEL"]!
        let managed = env["ESH_SDK_BENCH_LIFECYCLE"] == "managed"
        let root = env["ESH_SDK_BENCH_HOME"].map { PersistenceRoot(rootURL: URL(fileURLWithPath: $0)) } ?? .default()
        var backends: [BackendKind: any InferenceBackend] = [
            .gguf: LlamaCppEmbeddedBackend(config: LlamaCppConfig(contextTokens: script.contextTokens,
                                                                  reusePromptPrefix: env["ESH_SDK_BENCH_GGUF_REUSE"] == "1")),
        ]
        #if os(macOS)
        // Managed SDK on macOS = the same persistent, weights-resident MLX worker `esh serve` uses (ESH_MLX_PERSISTENT=1).
        backends[.mlx] = MLXBackend(persistent: managed)
        #endif
        let runtime = EshRuntime(registry: InferenceBackendRegistry(backends: backends),
                                 installProvider: FileInstallProvider(root: root),
                                 lifecycle: managed ? .managed(.init(maxConcurrentRequests: 3)) : .oneShot)
        let baseline = treeRSSGB()
        let sampler = PeakSampler(); sampler.start()
        var record: [String: Any] = ["side": "sdk", "lifecycle": managed ? "managed" : "oneShot", "model": model,
                                     "ggufPrefixReuse": env["ESH_SDK_BENCH_GGUF_REUSE"] == "1",
                                     "baselineRssGB": r2(baseline)]
        let t0 = Date()
        let long = try await converse(runtime, model: model, turns: script.long, maxTokens: script.maxTokens)
        record["long"] = [
            "ttft": long.map { r2($0.ttft) }, "e2e": long.map { r2($0.e2e) },
            "sessionSeconds": r2(Date().timeIntervalSince(t0)),
            "decodeTokPerSec": long.map { r2($0.metrics.tokensPerSecond) },
            "promptTokPerSec": long.map { r2($0.metrics.promptTokensPerSecond) },
            "promptTokens": long.map { $0.metrics.promptTokens ?? -1 },
            "generationTokens": long.map { $0.metrics.generationTokens ?? -1 },
            "cachedTokens": long.map { $0.metrics.cachedTokens ?? 0 },
            "cacheHit": long.map { $0.metrics.cacheHit ?? false },
            "prefixCacheMode": long.last?.metrics.prefixCacheMode ?? NSNull(),
        ]
        // Concurrency: N conversations at once; each must equal its own serial run (session isolation). Skippable: a
        // one-shot runtime loads one model copy PER concurrent request, which for an 8B MLX model would need ~16 GB.
        let skipConcurrent = env["ESH_SDK_BENCH_SKIP_CONCURRENT"] == "1"
        let concurrentScript = skipConcurrent ? [] : script.concurrent
        var serial: [[String]] = []
        for convo in concurrentScript { serial.append(try await converse(runtime, model: model, turns: convo, maxTokens: script.maxTokens).map(\.text)) }
        let c0 = Date()
        let parallel = try await withThrowingTaskGroup(of: (Int, [String]).self) { group in
            for (i, convo) in concurrentScript.enumerated() {
                group.addTask { (i, try await converse(runtime, model: model, turns: convo, maxTokens: script.maxTokens).map(\.text)) }
            }
            var out = Array(repeating: [String](), count: concurrentScript.count)
            for try await (i, texts) in group { out[i] = texts }
            return out
        }
        record["concurrent"] = skipConcurrent ? ["skipped": true] as [String: Any] : ["wallSeconds": r2(Date().timeIntervalSince(c0)),
                                "equalsSerial": zip(parallel, serial).map { $0 == $1 }]
        let status = await runtime.runtimeStatus()
        record["pool"] = status.pool.map { p in
            ["residents": p.residents.map { ["modelID": $0.modelID, "state": $0.state, "residency": $0.residency,
                                              "loadCount": $0.loadCount, "measuredMemoryBytes": $0.measuredMemoryBytes ?? -1,
                                              "residentCacheBytes": $0.residentCacheBytes ?? 0,
                                              "prefixCacheMode": $0.prefixCacheMode ?? ""] as [String: Any] },
             "residentCacheGB": p.residentCacheGB ?? 0] as [String: Any]
        } ?? NSNull()
        record["peakRssGB"] = r2(sampler.stop())
        record["rssBeforeShutdownGB"] = r2(treeRSSGB())
        await runtime.shutdown()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        record["rssAfterShutdownGB"] = r2(treeRSSGB())
        record["childProcessesAfterShutdown"] = childProcesses()
        record["texts"] = long.map(\.text)
        record["date"] = ISO8601DateFormatter().string(from: Date())
        if let out = env["ESH_SDK_BENCH_OUT"] {
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            if !FileManager.default.fileExists(atPath: out) { FileManager.default.createFile(atPath: out, contents: nil) }
            let h = try FileHandle(forWritingTo: URL(fileURLWithPath: out)); h.seekToEndOfFile(); h.write(data + Data("\n".utf8)); try h.close()
        }
        #expect(long.allSatisfy { !$0.text.isEmpty })
        #expect(zip(parallel, serial).allSatisfy { $0 == $1 }, "concurrent conversations differed from their serial runs")
        #expect(childProcesses().isEmpty, "child processes left after shutdown: \(childProcesses())")
    }
}
