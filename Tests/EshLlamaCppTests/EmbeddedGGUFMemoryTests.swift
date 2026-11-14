import Foundation
import Testing
import EshCore
@testable import EshRuntime
@testable import EshLlamaCpp

// Phase 1 (P0) — embedded llama.cpp resource ownership, verified with REAL runtime memory measurements.
//
// Env-gated: set ESH_GGUF_TEST_MODEL to a small local GGUF file (e.g. Qwen2.5-0.5B-Instruct Q4_K_M). Every test
// records the process physical footprint (task_vm_info.phys_footprint — what Jetsam/Activity Monitor charge the
// app, Metal buffers included) after each turn, and appends a JSON line per test to ESH_GGUF_MEMORY_REPORT when set.
//
// What each test separates:
//   * leak            — memory that keeps climbing with every turn and is never returned (allocations with no owner)
//   * KV growth        — llama.cpp pre-allocates the whole n_ctx KV buffer at context creation, so KV growth shows
//                        up as *logical* positions (context overflow), not as footprint growth
//   * allocator caching — the first load/unload cycles raise a high-water mark that later cycles reuse (plateau)

enum GGUFTestEnv {
    static var modelPath: String? {
        guard let p = ProcessInfo.processInfo.environment["ESH_GGUF_TEST_MODEL"], FileManager.default.fileExists(atPath: p)
        else { return nil }
        return p
    }
    static var enabled: Bool { modelPath != nil }
    static var turns: Int { Int(ProcessInfo.processInfo.environment["ESH_GGUF_TEST_TURNS"] ?? "") ?? 30 }
    /// Hard ceiling on growth above the starting footprint. A leak run stops here instead of pushing the Mac into swap.
    static var ceilingBytes: Int64 { Int64(ProcessInfo.processInfo.environment["ESH_GGUF_TEST_CEILING_MB"].flatMap(Int64.init) ?? 3072) * 1_048_576 }

    static func install(id: String = "gguf-test", path: String) -> ModelInstall {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 1
        return ModelInstall(id: id, spec: ModelSpec(id: id, displayName: id, backend: .gguf,
                                                    source: ModelSource(kind: .localPath, reference: path), localPath: path),
                            installPath: path, sizeBytes: size, backendFormat: "gguf")
    }

    static func report(_ name: String, _ payload: [String: Any]) {
        guard let out = ProcessInfo.processInfo.environment["ESH_GGUF_MEMORY_REPORT"] else { return }
        var body = payload; body["test"] = name; body["date"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return }
        let url = URL(fileURLWithPath: out)
        if !FileManager.default.fileExists(atPath: out) { FileManager.default.createFile(atPath: out, contents: nil) }
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data + Data("\n".utf8)); try? h.close() }
    }
}

/// Process physical footprint in bytes (same number Xcode's memory gauge and Jetsam use).
func physFootprint() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : -1
}

private func mb(_ b: Int64) -> Double { (Double(b) / 1_048_576 * 10).rounded() / 10 }

private let prompts = [
    "Name one prime number.", "What colour is the sky?", "Say hi.", "Give one word for happy.",
    "What is 2+2?", "Name a fruit.", "Name a planet.", "Say yes or no.",
]

@Suite(.serialized, .enabled(if: GGUFTestEnv.enabled, "set ESH_GGUF_TEST_MODEL to a local GGUF file"))
struct EmbeddedGGUFMemoryTests {

    /// The public one-shot facade (`EshRuntime.generate`) run for N sequential turns. Before the Phase-1 fix every
    /// call loaded a fresh llama model + context and nothing freed it, so the footprint climbed by a full context per
    /// turn. After the fix the one-shot path releases the runtime when the call ends: footprint stays flat.
    @Test func oneShotFacadeRepeatedTurnsDoesNotLeak() async throws {
        let path = try #require(GGUFTestEnv.modelPath)
        let install = GGUFTestEnv.install(path: path)
        let runtime = EshRuntime(registry: InferenceBackendRegistry(backends: [.gguf: LlamaCppEmbeddedBackend()]),
                                 installProvider: StaticInstallProvider([install]))
        let start = physFootprint()
        var samples: [Double] = []
        var stoppedAt: Int?
        for turn in 0..<GGUFTestEnv.turns {
            let r = try await runtime.generate(EshGenerationRequest(
                prompt: prompts[turn % prompts.count], constraints: .pinned(install.id),
                config: GenerationConfig(maxTokens: 12, temperature: 0)))
            #expect(!r.text.isEmpty)
            let now = physFootprint()
            samples.append(mb(now))
            if now - start > GGUFTestEnv.ceilingBytes { stoppedAt = turn + 1; break }
        }
        let growthAfterWarmup = samples.count > 3 ? samples.last! - samples[2] : 0
        GGUFTestEnv.report("oneShotFacade", ["startMB": mb(start), "afterTurnMB": samples, "stoppedAtCeilingTurn": stoppedAt as Any,
                                            "growthAfterTurn3MB": growthAfterWarmup])
        #expect(stoppedAt == nil, "footprint crossed the ceiling at turn \(stoppedAt ?? -1): leaked per-call contexts")
        // A turn's worth of KV/compute buffers is tens of MB; 30 leaked contexts would be several hundred MB to GB.
        #expect(growthAfterWarmup < 64, "footprint grew \(growthAfterWarmup) MB after warm-up across \(samples.count) turns")
    }

    /// One loaded runtime reused for N turns (what a managed pool does). Each turn must be independent of the previous
    /// one: the context's KV must be reset per request, otherwise turn k decodes on top of turns 1…k-1 and eventually
    /// overflows n_ctx. Output must equal a fresh-context run (greedy) and footprint must stay flat.
    @Test func reusedRuntimeIsIndependentPerTurnAndFlat() async throws {
        let path = try #require(GGUFTestEnv.modelPath)
        let install = GGUFTestEnv.install(path: path)
        let backend = LlamaCppEmbeddedBackend(config: LlamaCppConfig(contextTokens: 512))
        let config = GenerationConfig(maxTokens: 12, temperature: 0)
        func once(_ rt: BackendRuntime, _ p: String) async throws -> String {
            let s = ChatSession(name: "t", modelID: install.id, backend: .gguf, messages: [Message(role: .user, text: p)])
            var text = ""
            for try await c in rt.generate(session: s, config: config) { text += c }
            return text
        }
        // Reference outputs from a fresh context per prompt.
        var reference: [String: String] = [:]
        for p in prompts {
            let fresh = try await backend.loadRuntime(for: install)
            reference[p] = try await once(fresh, p)
            await fresh.unload()
        }
        let rt = try await backend.loadRuntime(for: install)
        let start = physFootprint()
        var samples: [Double] = []
        var mismatches: [Int] = []
        var failures: [String] = []
        for turn in 0..<GGUFTestEnv.turns {
            let p = prompts[turn % prompts.count]
            do {
                let out = try await once(rt, p)
                if out != reference[p] { mismatches.append(turn + 1) }
            } catch { failures.append("turn \(turn + 1): \(error)") ; break }
            samples.append(mb(physFootprint()))
        }
        await rt.unload()
        let growth = samples.count > 1 ? samples.last! - samples.first! : 0
        GGUFTestEnv.report("reusedRuntime", ["startMB": mb(start), "afterTurnMB": samples, "mismatchedTurns": mismatches,
                                            "failures": failures, "growthMB": growth])
        #expect(failures.isEmpty, "\(failures)")
        #expect(mismatches.isEmpty, "turns whose output differed from a fresh context: \(mismatches)")
        #expect(growth < 32, "footprint grew \(growth) MB while reusing one context")
    }

    /// Explicit load → generate → unload, repeated. Memory must return to a plateau: a rising first few cycles is the
    /// allocator/Metal heap caching its high-water mark; a slope that never flattens would be a genuine leak.
    @Test func repeatedLoadUnloadReturnsToPlateau() async throws {
        let path = try #require(GGUFTestEnv.modelPath)
        let install = GGUFTestEnv.install(path: path)
        let backend = LlamaCppEmbeddedBackend()
        let before = physFootprint()
        var afterUnload: [Double] = []
        var loaded: [Double] = []
        for _ in 0..<GGUFTestEnv.turns {
            let rt = try await backend.loadRuntime(for: install)
            let s = ChatSession(name: "t", modelID: install.id, backend: .gguf, messages: [Message(role: .user, text: "Say hi.")])
            for try await _ in rt.generate(session: s, config: GenerationConfig(maxTokens: 4, temperature: 0)) {}
            loaded.append(mb(physFootprint()))
            await rt.unload()
            afterUnload.append(mb(physFootprint()))
            if physFootprint() - before > GGUFTestEnv.ceilingBytes { break }
        }
        let n = afterUnload.count
        let lateSlope = n >= 10 ? (afterUnload[n - 1] - afterUnload[n / 2]) : 0
        GGUFTestEnv.report("loadUnloadCycles", ["beforeMB": mb(before), "loadedMB": loaded, "afterUnloadMB": afterUnload,
                                               "lateSlopeMB": lateSlope])
        #expect(lateSlope < 32, "memory after unload kept climbing in the second half: +\(lateSlope) MB")
    }

    /// Dropping the last reference to a runtime without calling `unload()` must still free the native model/context
    /// (deterministic `deinit`), so a host that forgets `unload` — or a cancelled task — does not leak.
    @Test func droppingRuntimeWithoutUnloadFreesNativeMemory() async throws {
        let path = try #require(GGUFTestEnv.modelPath)
        let install = GGUFTestEnv.install(path: path)
        let backend = LlamaCppEmbeddedBackend()
        let before = physFootprint()
        var samples: [Double] = []
        for _ in 0..<GGUFTestEnv.turns {
            do {
                let rt = try await backend.loadRuntime(for: install)
                let s = ChatSession(name: "t", modelID: install.id, backend: .gguf, messages: [Message(role: .user, text: "Say hi.")])
                for try await _ in rt.generate(session: s, config: GenerationConfig(maxTokens: 4, temperature: 0)) {}
            }   // rt goes out of scope here — no unload()
            try await Task.sleep(nanoseconds: 50_000_000)
            samples.append(mb(physFootprint()))
            if physFootprint() - before > GGUFTestEnv.ceilingBytes { break }
        }
        let n = samples.count
        let lateSlope = n >= 10 ? samples[n - 1] - samples[n / 2] : 0
        GGUFTestEnv.report("dropWithoutUnload", ["beforeMB": mb(before), "afterDropMB": samples, "lateSlopeMB": lateSlope])
        #expect(n == GGUFTestEnv.turns, "stopped at the memory ceiling after \(n) cycles: dropped runtimes leak")
        #expect(lateSlope < 32, "memory after dropping runtimes kept climbing: +\(lateSlope) MB")
    }

    /// Cancelling mid-generation leaves the runtime usable and the next turn independent of the cancelled one.
    @Test func cancellationLeavesRuntimeReusable() async throws {
        let path = try #require(GGUFTestEnv.modelPath)
        let install = GGUFTestEnv.install(path: path)
        let backend = LlamaCppEmbeddedBackend(config: LlamaCppConfig(contextTokens: 512))
        let rt = try await backend.loadRuntime(for: install)
        defer { Task { await rt.unload() } }
        let s = ChatSession(name: "t", modelID: install.id, backend: .gguf,
                            messages: [Message(role: .user, text: "Count from 1 to 200 separated by spaces.")])
        let task = Task { () -> Int in
            var n = 0
            for try await _ in rt.generate(session: s, config: GenerationConfig(maxTokens: 400, temperature: 0)) {
                n += 1; if n == 5 { withUnsafeCurrentTask { $0?.cancel() } }
            }
            return n
        }
        let produced = (try? await task.value) ?? 0
        #expect(produced < 400)
        let fresh = try await backend.loadRuntime(for: install)
        let p = ChatSession(name: "t", modelID: install.id, backend: .gguf, messages: [Message(role: .user, text: "Say hi.")])
        var a = "", b = ""
        for try await c in rt.generate(session: p, config: GenerationConfig(maxTokens: 8, temperature: 0)) { a += c }
        for try await c in fresh.generate(session: p, config: GenerationConfig(maxTokens: 8, temperature: 0)) { b += c }
        await fresh.unload()
        #expect(a == b, "turn after a cancelled one differs from a fresh context: \(a.debugDescription) vs \(b.debugDescription)")
    }

    /// Opt-in prefix reuse (`LlamaCppConfig.reusePromptPrefix`): a growing multi-turn conversation must hit the cache
    /// from turn 2, produce the same greedy text as a full prefill, and an unrelated conversation in between must not
    /// be influenced by the cached one (isolation: only the common token prefix is kept).
    @Test func promptPrefixReuseHitsAndMatchesFullPrefill() async throws {
        let path = try #require(GGUFTestEnv.modelPath)
        let install = GGUFTestEnv.install(path: path)
        let reuse = try await LlamaCppEmbeddedBackend(config: LlamaCppConfig(contextTokens: 4096, reusePromptPrefix: true))
            .loadRuntime(for: install)
        let full = try await LlamaCppEmbeddedBackend(config: LlamaCppConfig(contextTokens: 4096)).loadRuntime(for: install)
        let config = GenerationConfig(maxTokens: 24, temperature: 0)
        func run(_ rt: BackendRuntime, _ msgs: [Message]) async throws -> (String, Metrics) {
            let s = ChatSession(name: "t", modelID: install.id, backend: .gguf, messages: msgs)
            var text = ""
            for try await c in rt.generate(session: s, config: config) { text += c }
            return (text, await rt.metrics)
        }
        let questions = ["Name a prime number.", "Double it.", "Is that even?", "Name a colour.", "Name a fruit of that colour.",
                         "Spell it backwards.", "How many letters?", "Name a planet.", "Is it bigger than Earth?", "Say goodbye."]
        var msgs = [Message(role: .system, text: "You are terse. Answer in a few words.")]
        var matches: [Bool] = [], cached: [Int] = [], isolation: [Bool] = []
        for (i, q) in questions.enumerated() {
            msgs.append(Message(role: .user, text: q))
            let (a, m) = try await run(reuse, msgs)
            let (b, _) = try await run(full, msgs)
            matches.append(a == b); cached.append(m.cachedTokens ?? 0)
            msgs.append(Message(role: .assistant, text: b))
            if i == 4 {   // an unrelated request between turns: must equal its full-prefill answer
                let other = [Message(role: .user, text: "What is 7 times 6?")]
                let (x, _) = try await run(reuse, other)
                let (y, _) = try await run(full, other)
                isolation.append(x == y)
            }
        }
        await reuse.unload(); await full.unload()
        GGUFTestEnv.report("promptPrefixReuse", ["matchesFullPrefill": matches, "cachedTokens": cached, "isolation": isolation])
        #expect(cached.dropFirst().allSatisfy { $0 > 0 }, "no cache hit after turn 1: \(cached)")
        #expect(isolation.allSatisfy { $0 })
        #expect(matches.allSatisfy { $0 }, "outputs differing from a full prefill at turns: \(matches.enumerated().filter { !$0.element }.map { $0.offset + 1 })")
    }
}
