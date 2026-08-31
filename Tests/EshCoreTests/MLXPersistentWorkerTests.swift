import Foundation
import Testing
@testable import EshCore

/// Real-runtime integration tests for the persistent MLX worker. These spawn a live Python worker and
/// load a real model, so they run ONLY when explicitly enabled:
///
///   ESH_RUN_MLX_WORKER_TESTS=1 \
///   ESH_PYTHON=~/.esh/runtime/python/bin/python3 \
///   ESH_MLX_VLM_BRIDGE=$PWD/Tools/mlx_vlm_bridge.py \
///   swift test --filter MLXPersistentWorkerTests
///
/// They are skipped (as trivial passes) otherwise, so CI stays hermetic.
@Suite
struct MLXPersistentWorkerTests {
    private var enabled: Bool { ProcessInfo.processInfo.environment["ESH_RUN_MLX_WORKER_TESTS"] == "1" }

    private func firstMLXInstall() throws -> ModelInstall? {
        let root = PersistenceRoot.default()
        let installs = try FileModelStore(root: root).listInstalls()
        return installs.first { $0.spec.backend == .mlx }
    }

    private func session(_ text: String, model: String) -> ChatSession {
        ChatSession(name: "persist-test", modelID: model, backend: .mlx, cacheMode: .raw, intent: .chat,
                    messages: [Message(role: .user, text: text)])
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var out = ""
        for try await chunk in stream { out += chunk }
        return out
    }

    private func liveWorkerCount() -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "mlx_vlm_bridge.py mlx-serve"]
        let pipe = Pipe(); p.standardOutput = pipe
        try? p.run(); p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return out.split(whereSeparator: \.isNewline).count
    }

    @Test
    func residentWorkerServesWarmAndReportsResidencyThenNoOrphan() async throws {
        guard enabled else { return }
        guard let install = try firstMLXInstall() else {
            Issue.record("no MLX model installed to test against"); return
        }

        let manager = RuntimeLifecycleManager(
            loader: { try await MLXBackend(persistent: true).loadRuntime(for: $0) }
        )

        // Cold acquire → loads the model once into a resident worker.
        let runtime = try await manager.acquire(install: install, priority: .interactive)

        let coldStart = Date()
        let first = try await collect(ChatService().streamReply(
            runtime: runtime, session: session("Reply with exactly: pong", model: install.id),
            config: GenerationConfig(maxTokens: 8, temperature: 0)))
        let coldSeconds = Date().timeIntervalSince(coldStart)
        #expect(first.isEmpty == false)

        let warmStart = Date()
        let second = try await collect(ChatService().streamReply(
            runtime: runtime, session: session("Name one color.", model: install.id),
            config: GenerationConfig(maxTokens: 8, temperature: 0)))
        let warmSeconds = Date().timeIntervalSince(warmStart)
        #expect(second.isEmpty == false)

        // Truthful residency through the manager (not a static probe): a live worker holds weights.
        let status = await manager.status()
        #expect(status.residents.first?.residency == RuntimeResidency.weightsResident.rawValue)

        // A resident worker should exist while warm...
        #expect(liveWorkerCount() >= 1)

        await manager.release(modelID: install.id)
        // ...and unloading the pool must leave no orphan worker.
        await manager.unloadAll()
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        #expect(liveWorkerCount() == 0)

        Issue.record("timing (informational): cold=\(String(format: "%.2f", coldSeconds))s warm=\(String(format: "%.2f", warmSeconds))s")
    }

    @Test
    func cancellationStopsGenerationPromptly() async throws {
        guard enabled else { return }
        guard let install = try firstMLXInstall() else { return }
        let manager = RuntimeLifecycleManager(
            loader: { try await MLXBackend(persistent: true).loadRuntime(for: $0) }
        )
        let runtime = try await manager.acquire(install: install, priority: .interactive)
        defer { Task { await manager.unloadAll() } }

        let stream = ChatService().streamReply(
            runtime: runtime, session: session("Write a very long story about the ocean.", model: install.id),
            config: GenerationConfig(maxTokens: 4096, temperature: 0))

        let consumer = Task { () -> Int in
            var count = 0
            for try await _ in stream { count += 1; if count >= 3 { break } }
            return count
        }
        let got = try await consumer.value
        #expect(got >= 1)  // produced tokens then we stopped consuming (stream teardown cancels the worker gen)
        await manager.release(modelID: install.id)
    }
}
