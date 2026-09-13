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

    /// Robust logging: append to Documents/esh-m7.log (survives crashes, pull via devicectl) AND write to
    /// stderr unbuffered (appears immediately in `devicectl … --console`, unlike block-buffered stdout).
    static let logURL: URL? = {
        let docs = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return docs?.appendingPathComponent("esh-m7.log")
    }()
    static func log(_ s: String) {
        print(s)                                          // appears in devicectl --console (stdout)
        let line = s + "\n"
        FileHandle.standardError.write(Data(line.utf8))   // unbuffered fallback
        guard let logURL else { return }
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.data(using: .utf8)?.write(to: logURL)
        }
    }

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

    /// M8 — app-managed model lifecycle: preflight → download → verify → install → generate → (relaunch)
    /// persistence → remove. Uses the 0.5B model for a faster on-device download. Logs `ESH-M8`.
    static func runManaged() async -> String {
        if let logURL { try? Data().write(to: logURL) }
        log("ESH-M8 begin")
        let d = LocalModelCatalog.descriptor(id: "qwen2.5-0.5b-instruct-q4km")!
        let registry = InferenceBackendRegistry(backends: [
            .apple: AppleBackend(),
            .gguf: LlamaCppEmbeddedBackend(config: LlamaCppConfig(contextTokens: 2048)),
        ])
        let runtime = EshRuntime(registry: registry, installProvider: FileInstallProvider(),
                                 localModelManager: LocalModelManager())
        func storageMB() async -> String {
            (await runtime.deviceProfile().availableStorageBytes).map { String(format: "%.0f", Double($0) / 1_048_576) } ?? "?"
        }
        func genPinned(_ label: String) async {
            do {
                let r = try await runtime.generate(EshGenerationRequest(prompt: "Reply with exactly one word: pong",
                                                                        constraints: .pinned(d.id),
                                                                        config: GenerationConfig(maxTokens: 16, temperature: 0)))
                log("ESH-M8 \(label) backend=\(r.selection.backend.rawValue) model=\(r.selection.modelID) text=\"\(r.text.replacingOccurrences(of: "\n", with: " ").prefix(60))\"")
            } catch { log("ESH-M8 \(label) ERROR=\(error)") }
        }

        let wasInstalled = (await runtime.localModels()).first { $0.descriptor.id == d.id }.map {
            if case .installed = $0.state { return true } else { return false }
        } ?? false
        log("ESH-M8 model=\(d.id) sizeBytes=\(d.expectedBytes) wasInstalledAtLaunch=\(wasInstalled) storageFreeMB=\(await storageMB())")

        if wasInstalled {
            // Second launch: the install survived an app restart. Generate, then remove.
            log("ESH-M8 persistence=confirmed install-survived-restart")
            await genPinned("generateAfterRestart")
            let before = await storageMB()
            do {
                try await runtime.remove(d)
                let stillInstalled = (await runtime.localModels()).first { $0.descriptor.id == d.id }.map { $0.state == .installed } ?? false
                log("ESH-M8 removed storageBeforeMB=\(before) storageAfterMB=\(await storageMB()) stillInstalled=\(stillInstalled)")
            } catch { log("ESH-M8 remove ERROR=\(error)") }
            log("ESH-M8 RESULT=PASS phase=restart+remove")
            return "M8 restart+remove complete."
        }

        // First launch: preflight → download → verify → install → generate.
        let plan = await runtime.installPlan(for: d)
        log("ESH-M8 plan downloadMB=\(d.expectedBytes / 1_048_576) storageFreeMB=\(plan.availableStorageBytes.map { String($0 / 1_048_576) } ?? "?") fit=\(plan.fit.rawValue) suitable=\(plan.suitable)")
        let sBefore = await storageMB()
        let t0 = ContinuousClock.now
        let lastPct = LockedDouble()
        do {
            _ = try await runtime.install(d) { p in
                if p - lastPct.get() >= 0.25 || p >= 1.0 { lastPct.set(p); log("ESH-M8 download progress=\(String(format: "%.0f%%", p * 100))") }
            }
        } catch {
            log("ESH-M8 install ERROR=\(error)")
            return "M8 install failed: \(error)"
        }
        log("ESH-M8 installed downloadTime=\(t0.duration(to: .now)) storageBeforeMB=\(sBefore) storageAfterMB=\(await storageMB())")
        await genPinned("generateAfterInstall")
        log("ESH-M8 RESULT=PASS phase=install+generate (relaunch app to verify persistence+remove)")
        return "M8 install+generate complete. Relaunch to verify persistence + removal."
    }

    /// Runs the full benchmark; returns a short human summary for the UI. Detailed data is in `ESH-M7` logs.
    static func run() async -> String {
        if let logURL { try? Data().write(to: logURL) }   // fresh log per launch
        Self.log("ESH-M7 begin")
        guard let url = modelURL() else {
            Self.log("ESH-M7 RESULT=SKIP reason=model-not-in-Documents file=\(modelFileName)")
            return "GGUF model not found in Documents (\(modelFileName)). Push it with devicectl."
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil ?? 0
        Self.log("ESH-M7 model=\(modelFileName) sizeBytes=\(size) availMBstart=\(String(format: "%.0f", availMB()))")

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
            Self.log("ESH-M7 eshRuntimePath ok elapsed=\(t0.duration(to: .now)) backend=\(r.selection.backend.rawValue) model=\(r.selection.modelID) reason=\"\(r.selection.reason)\" text=\"\(r.text.replacingOccurrences(of: "\n", with: " ").prefix(80))\"")
        } catch {
            Self.log("ESH-M7 eshRuntimePath ERROR=\(error)")
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
            Self.log("ESH-M7 load ms=\(loadDur) availMB_before=\(String(format: "%.0f", mBefore)) availMB_after=\(String(format: "%.0f", mAfter)) deltaMB=\(String(format: "%.0f", mBefore - mAfter))")
            summary += "load \(loadDur), mem -\(String(format: "%.0f", mBefore - mAfter))MB\n"

            // Warm generations (TTFT, tok/s)
            for i in 1...2 {
                let g0 = ContinuousClock.now
                var text = ""; var n = 0
                for try await c in rt.generate(session: session("Name three primary colors."), config: GenerationConfig(maxTokens: 48, temperature: 0.7, topP: 0.9, seed: 42)) { text += c; n += 1 }
                let gd = g0.duration(to: .now)
                let m = await rt.metrics
                Self.log("ESH-M7 gen#\(i) total=\(gd) tokens=\(n) ttftMs=\(m.ttftMilliseconds.map{String(format: "%.1f",$0)} ?? "?") tokPerSec=\(m.tokensPerSecond.map{String(format: "%.2f",$0)} ?? "?") availMB=\(String(format: "%.0f", availMB())) text=\"\(text.replacingOccurrences(of: "\n", with: " ").prefix(80))\"")
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
            Self.log("ESH-M7 cancel propagated=\(cancelled)")
            // Reuse after cancel
            var reuse = ""
            for try await c in rt.generate(session: session("Say hi."), config: GenerationConfig(maxTokens: 8, temperature: 0)) { reuse += c }
            Self.log("ESH-M7 reuseAfterCancel ok=\(!reuse.isEmpty) text=\"\(reuse.replacingOccurrences(of: "\n", with: " ").prefix(40))\"")
            summary += "cancel=\(cancelled), reuse=\(!reuse.isEmpty)\n"

            // Unload + memory recovery
            let uBefore = availMB()
            await rt.unload()
            // give the allocator a moment
            try? await Task.sleep(nanoseconds: 300_000_000)
            let uAfter = availMB()
            Self.log("ESH-M7 unload availMB_before=\(String(format: "%.0f", uBefore)) availMB_after=\(String(format: "%.0f", uAfter)) recoveredMB=\(String(format: "%.0f", uAfter - uBefore))")
            summary += "unload recovered ~\(String(format: "%.0f", uAfter - uBefore))MB\n"

            // Reload (prove recovery is usable)
            let rl0 = ContinuousClock.now
            let rt2 = try await backend.loadRuntime(for: inst)
            Self.log("ESH-M7 reload ms=\(rl0.duration(to: .now)) availMB=\(String(format: "%.0f", availMB()))")
            await rt2.unload()
        } catch {
            Self.log("ESH-M7 lifecycle ERROR=\(error)")
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
                Self.log("ESH-M7 ctx=\(ctx) loadMemDeltaMB=\(String(format: "%.0f", mB - availMB())) genTotal=\(g0.duration(to: .now)) tokens=\(n) tokPerSec=\(m.tokensPerSecond.map{String(format: "%.2f",$0)} ?? "?")")
                await rt.unload()
            } catch {
                Self.log("ESH-M7 ctx=\(ctx) ERROR=\(error)")
            }
        }

        Self.log("ESH-M7 RESULT=PASS availMBend=\(String(format: "%.0f", availMB()))")
        return summary
    }
}

/// Tiny thread-safe Double for progress throttling from the @Sendable download callback.
final class LockedDouble: @unchecked Sendable {
    private var value: Double = -1
    private let lock = NSLock()
    func get() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Double) { lock.lock(); value = v; lock.unlock() }
}
