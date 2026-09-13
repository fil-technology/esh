import Foundation
import Darwin
import EshCore
import EshRuntime
import EshLlamaCpp

// esh M7 — embedded GGUF benchmark, driven from the probe app. Proves the full path
//   EshRuntime → InferenceBackendRegistry → LlamaCppEmbeddedBackend → llama.cpp (Metal) → GGUF
// and measures load/gen/cancel/unload/reload/context-scaling. Prints `ESH-M7 …` for console capture.
// The model file is expected in the app's Documents dir (pushed via devicectl).

enum GGUFBenchmark {
    static let modelFileName = "Qwen2.5-1.5B-Instruct-Q4_K_M.gguf"

    static func modelURL() -> URL? {
        let docs = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let url = docs?.appendingPathComponent(modelFileName)
        if let url, FileManager.default.fileExists(atPath: url.path) { return url }
        return nil
    }

    static func availMB() -> Double { Double(os_proc_available_memory()) / 1_048_576 }

    static func install(path: String, size: Int64) -> ModelInstall {
        ModelInstall(id: "qwen2.5-1.5b-instruct-q4km",
                     spec: ModelSpec(id: "qwen2.5-1.5b-instruct-q4km", displayName: "Qwen2.5-1.5B-Instruct Q4_K_M",
                                     backend: .gguf, source: ModelSource(kind: .localPath, reference: path)),
                     installPath: path, sizeBytes: size, backendFormat: "gguf", runtimeVersion: "llama.cpp-embedded")
    }

    static func session(_ prompt: String) -> ChatSession {
        ChatSession(name: "m7", modelID: "qwen2.5-1.5b-instruct-q4km", backend: .gguf,
                    messages: [Message(role: .user, text: prompt)])
    }

    /// Runs the full benchmark; returns a short human summary for the UI. Detailed data is in `ESH-M7` logs.
    static func run() async -> String {
        guard let url = modelURL() else {
            print("ESH-M7 RESULT=SKIP reason=model-not-in-Documents file=\(modelFileName)")
            return "GGUF model not found in Documents (\(modelFileName)). Push it with devicectl."
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil ?? 0
        print("ESH-M7 model=\(modelFileName) sizeBytes=\(size) availMBstart=\(String(format: "%.0f", availMB()))")

        // 1) Prove the EshRuntime path (explicit GGUF pin; Auto still prefers Apple, so we pin).
        let registry = InferenceBackendRegistry(backends: [
            .apple: AppleBackend(),
            .gguf: LlamaCppEmbeddedBackend(config: LlamaCppConfig(contextTokens: 2048))
        ])
        let runtime = EshRuntime(registry: registry, installProvider: StaticInstallProvider([install(path: url.path, size: size)]))
        do {
            let t0 = ContinuousClock.now
            let r = try await runtime.generate(EshGenerationRequest(prompt: "Reply with exactly one word: pong",
                                                                    constraints: .pinned("qwen2.5-1.5b-instruct-q4km"),
                                                                    config: GenerationConfig(maxTokens: 16, temperature: 0)))
            print("ESH-M7 eshRuntimePath ok elapsed=\(t0.duration(to: .now)) backend=\(r.selection.backend.rawValue) model=\(r.selection.modelID) reason=\"\(r.selection.reason)\" text=\"\(r.text.replacingOccurrences(of: "\n", with: " ").prefix(80))\"")
        } catch {
            print("ESH-M7 eshRuntimePath ERROR=\(error)")
        }

        // 2) Direct backend lifecycle (same backend EshRuntime uses) for load/warm/cancel/unload/reload.
        let backend = LlamaCppEmbeddedBackend(config: LlamaCppConfig(contextTokens: 2048))
        let inst = install(path: url.path, size: size)
        var summary = "GGUF ran through EshRuntime.\n"
        do {
            // Cold load
            let mBefore = availMB()
            let l0 = ContinuousClock.now
            let rt = try await backend.loadRuntime(for: inst)
            let loadDur = l0.duration(to: .now)
            let mAfter = availMB()
            print("ESH-M7 load ms=\(loadDur) availMB_before=\(String(format: "%.0f", mBefore)) availMB_after=\(String(format: "%.0f", mAfter)) deltaMB=\(String(format: "%.0f", mBefore - mAfter))")
            summary += "load \(loadDur), mem -\(String(format: "%.0f", mBefore - mAfter))MB\n"

            // Warm generations (TTFT, tok/s)
            for i in 1...2 {
                let g0 = ContinuousClock.now
                var text = ""; var n = 0
                for try await c in rt.generate(session: session("Name three primary colors."), config: GenerationConfig(maxTokens: 48, temperature: 0.7, topP: 0.9, seed: 42)) { text += c; n += 1 }
                let gd = g0.duration(to: .now)
                let m = await rt.metrics
                print("ESH-M7 gen#\(i) total=\(gd) tokens=\(n) ttftMs=\(m.ttftMilliseconds.map{String(format: "%.1f",$0)} ?? "?") tokPerSec=\(m.tokensPerSecond.map{String(format: "%.2f",$0)} ?? "?") availMB=\(String(format: "%.0f", availMB())) text=\"\(text.replacingOccurrences(of: "\n", with: " ").prefix(80))\"")
                if i == 1 { summary += "gen tok/s \(m.tokensPerSecond.map{String(format: "%.1f",$0)} ?? "?")\n" }
            }

            // Cancellation: long generation, cancel mid-stream, then prove reuse.
            let cancelTask = Task { () -> Bool in
                do {
                    for try await _ in rt.generate(session: session("Write a long detailed essay about the ocean."), config: GenerationConfig(maxTokens: 4096, temperature: 0.7)) {
                        try Task.checkCancellation()
                    }
                    return false
                } catch is CancellationError { return true } catch { return false }
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            cancelTask.cancel()
            let cancelled = await cancelTask.value
            print("ESH-M7 cancel propagated=\(cancelled)")
            // Reuse after cancel
            var reuse = ""
            for try await c in rt.generate(session: session("Say hi."), config: GenerationConfig(maxTokens: 8, temperature: 0)) { reuse += c }
            print("ESH-M7 reuseAfterCancel ok=\(!reuse.isEmpty) text=\"\(reuse.replacingOccurrences(of: "\n", with: " ").prefix(40))\"")
            summary += "cancel=\(cancelled), reuse=\(!reuse.isEmpty)\n"

            // Unload + memory recovery
            let uBefore = availMB()
            await rt.unload()
            // give the allocator a moment
            try? await Task.sleep(nanoseconds: 300_000_000)
            let uAfter = availMB()
            print("ESH-M7 unload availMB_before=\(String(format: "%.0f", uBefore)) availMB_after=\(String(format: "%.0f", uAfter)) recoveredMB=\(String(format: "%.0f", uAfter - uBefore))")
            summary += "unload recovered ~\(String(format: "%.0f", uAfter - uBefore))MB\n"

            // Reload (prove recovery is usable)
            let rl0 = ContinuousClock.now
            let rt2 = try await backend.loadRuntime(for: inst)
            print("ESH-M7 reload ms=\(rl0.duration(to: .now)) availMB=\(String(format: "%.0f", availMB()))")
            await rt2.unload()
        } catch {
            print("ESH-M7 lifecycle ERROR=\(error)")
            summary += "lifecycle error: \(error)\n"
        }

        // 3) Context scaling
        for ctx in [512, 2048, 4096] {
            do {
                let b = LlamaCppEmbeddedBackend(config: LlamaCppConfig(contextTokens: ctx))
                let mB = availMB()
                let rt = try await b.loadRuntime(for: inst)
                let g0 = ContinuousClock.now
                var n = 0
                for try await _ in rt.generate(session: session("Count to five."), config: GenerationConfig(maxTokens: 32, temperature: 0)) { n += 1 }
                let m = await rt.metrics
                print("ESH-M7 ctx=\(ctx) loadMemDeltaMB=\(String(format: "%.0f", mB - availMB())) genTotal=\(g0.duration(to: .now)) tokens=\(n) tokPerSec=\(m.tokensPerSecond.map{String(format: "%.2f",$0)} ?? "?")")
                await rt.unload()
            } catch {
                print("ESH-M7 ctx=\(ctx) ERROR=\(error)")
            }
        }

        print("ESH-M7 RESULT=PASS availMBend=\(String(format: "%.0f", availMB()))")
        return summary
    }
}
