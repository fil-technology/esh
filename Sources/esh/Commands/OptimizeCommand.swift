import Foundation
import EshCore

/// `esh optimize` — inspect optimization strategies, plan an ExecutionProfile, and run the
/// evidence-driven benchmark harness. `esh performance <mode>` sets the default planning mode.
enum OptimizeCommand {
    static func run(arguments: [String], root: PersistenceRoot) async throws {
        let sub = arguments.first ?? "status"
        let rest = Array(arguments.dropFirst())
        let json = rest.contains("--json")

        switch sub {
        case "status":
            try status(root: root, json: json)
        case "strategies":
            try strategies(rest: rest, root: root, json: json)
        case "plan":
            try plan(rest: rest, root: root, json: json)
        case "benchmark":
            try await benchmark(rest: rest, root: root, json: json)
        case "compare":
            try compare(rest: rest, root: root, json: json)
        case "reset":
            try reset(rest: rest, root: root)
        default:
            throw StoreError.invalidManifest("Usage: esh optimize [status|strategies|plan <model>|benchmark <model>|compare <model>|reset <model>] [--json]")
        }
    }

    /// `esh performance auto|speed|balanced|memory`
    static func setPerformanceMode(arguments: [String], root: PersistenceRoot) throws {
        guard let value = arguments.first, let mode = PerformanceMode(cliValue: value) else {
            let current = (try? EshConfigStore(root: root).load().defaults.performanceMode) ?? "auto"
            print("Current performance mode: \(current)")
            print("Usage: esh performance <auto|speed|balanced|memory>")
            return
        }
        let store = EshConfigStore(root: root)
        var config = (try? store.load()) ?? .default
        config.defaults.performanceMode = mode.rawValue
        try store.save(config)
        print("Performance mode set to: \(mode.rawValue)")
        if mode == .auto {
            print("auto uses locally benchmarked strategies where available, else conservative defaults. Run `esh optimize benchmark <model>` to gather evidence.")
        }
    }

    // MARK: - status

    private static func status(root: PersistenceRoot, json: Bool) throws {
        let mode = (try? EshConfigStore(root: root).load().defaults.performanceMode) ?? "auto"
        let profileStore = OptimizationProfileStore(root: root)
        let results = profileStore.allResults()
        let registry = OptimizationStrategyRegistry()
        if json {
            printJSON([
                "performanceMode": mode,
                "optimizationSchemaVersion": OptimizationSchema.version,
                "strategyCount": registry.all.count,
                "benchmarkResultCount": results.count,
                "benchmarkedModels": Array(Set(results.map { $0.key.modelID })).sorted()
            ])
            return
        }
        print("performance mode: \(mode)")
        print("optimization schema: v\(OptimizationSchema.version)")
        print("registered strategies: \(registry.all.count)")
        print("benchmark results: \(results.count)")
        let models = Set(results.map { $0.key.modelID }).sorted()
        if models.isEmpty {
            print("benchmarked models: none — run `esh optimize benchmark <model>` to let auto use evidence")
        } else {
            print("benchmarked models: \(models.joined(separator: ", "))")
        }
    }

    // MARK: - strategies

    private static func strategies(rest: [String], root: PersistenceRoot, json: Bool) throws {
        let registry = OptimizationStrategyRegistry()
        let model = CommandSupport.optionalValue(flag: "--model", in: rest)
        let context = model.flatMap { resolveContext(model: $0, root: root) }

        if json {
            let items = registry.all.map { s -> [String: Any] in
                var d: [String: Any] = [
                    "id": s.id, "category": s.category.rawValue, "backends": s.backends.map(\.rawValue),
                    "qualityMayChange": s.qualityMayChange, "distributionEquivalent": s.distributionEquivalent,
                    "requiresBenchmarkBeforeAuto": s.requiresBenchmarkBeforeAuto, "experimental": s.experimental,
                    "baseline": s.isBaseline
                ]
                if let context { d["compatible"] = registry.compatibility(of: s, in: context).isCompatible }
                return d
            }
            printJSON(["strategies": items])
            return
        }

        print("id                category         backends     flags")
        for s in registry.all {
            var flags: [String] = []
            if s.isBaseline { flags.append("baseline") }
            if s.distributionEquivalent { flags.append("equivalent") }
            if s.qualityMayChange { flags.append("quality±") }
            if s.requiresBenchmarkBeforeAuto { flags.append("needs-benchmark") }
            if s.experimental { flags.append("experimental") }
            if let context {
                flags.append(registry.compatibility(of: s, in: context).isCompatible ? "compatible" : "incompatible")
            }
            print("\(pad(s.id, 17)) \(pad(s.category.rawValue, 16)) \(pad(s.backends.map(\.rawValue).joined(separator: ","), 12)) \(flags.joined(separator: " "))")
        }
    }

    // MARK: - plan

    private static func plan(rest: [String], root: PersistenceRoot, json: Bool) throws {
        let positional = CommandSupport.positionalArguments(in: rest, knownFlags: ["--workload", "--context", "--mode"]).filter { !$0.hasPrefix("--") }
        guard let model = positional.first else {
            throw StoreError.invalidManifest("Usage: esh optimize plan <model> [--workload chat|coding|reasoning|structured|agent|long] [--context N] [--mode auto|speed|balanced|memory]")
        }
        let workload = CommandSupport.optionalValue(flag: "--workload", in: rest).flatMap(OptimizationWorkload.init(cliValue:)) ?? .chat
        let contextTokens = CommandSupport.optionalValue(flag: "--context", in: rest).flatMap(Int.init)
        let configMode = (try? EshConfigStore(root: root).load().defaults.performanceMode) ?? "auto"
        let mode = CommandSupport.optionalValue(flag: "--mode", in: rest).flatMap(PerformanceMode.init(cliValue:)) ?? PerformanceMode(cliValue: configMode) ?? .auto

        guard let context = resolveContext(model: model, root: root) else {
            throw StoreError.invalidManifest("Could not resolve backend for \(model). Install it or specify a known model.")
        }
        let planner = OptimizationPlanner(store: OptimizationProfileStore(root: root))
        let profile = planner.plan(context: context, workload: workload, contextTokens: contextTokens, mode: mode)

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(profile), let text = String(data: data, encoding: .utf8) { print(text) }
            return
        }
        print("ExecutionProfile — \(model)")
        print("  \(profile.summaryLine)")
        print("  workload: \(workload.rawValue)\(contextTokens.map { " · context \($0)" } ?? "") · mode \(mode.rawValue)")
        print("  evidence-backed: \(profile.evidenceBacked ? "yes" : "no")")
        print("  reasons:")
        for r in profile.reasons { print("    - \(r)") }
    }

    // MARK: - benchmark

    private static func benchmark(rest: [String], root: PersistenceRoot, json: Bool) async throws {
        let positional = CommandSupport.positionalArguments(in: rest, knownFlags: ["--workload"]).filter { !$0.hasPrefix("--") }
        guard let model = positional.first else {
            throw StoreError.invalidManifest("Usage: esh optimize benchmark <model> [--quick|--full] [--workload <w>]")
        }
        let installs = (try? FileModelStore(root: root).listInstalls()) ?? []
        guard let install = installs.first(where: { $0.id == model || $0.spec.source.reference == model }) else {
            throw StoreError.notFound("Model \(model) is not installed. Install it first with `esh model install \(model)`. Benchmarking runs real inference and needs local weights.")
        }
        let options: BenchmarkOptions = rest.contains("--full") ? .full : (rest.contains("--quick") ? .quick : BenchmarkOptions())
        var scenarios = BenchmarkScenario.v1Suite
        if let w = CommandSupport.optionalValue(flag: "--workload", in: rest).flatMap(OptimizationWorkload.init(cliValue:)) {
            scenarios = scenarios.filter { $0.workload == w }
        }
        let host = HostMachineProfileService().currentProfile()
        let harness = BenchmarkHarness(eshVersion: AppVersionResolver.currentVersion())
        let runner = ProductionBenchmarkRunner(root: root)
        let now = ISO8601DateFormatter().string(from: Date())

        print("Benchmarking \(install.id) [\(install.spec.backend.rawValue)] through the real inference path…")
        print("This runs multiple generations per strategy/scenario and may take a while.")
        let results = await harness.benchmarkKVCache(
            model: install.id,
            backend: install.spec.backend,
            host: host,
            runtimeVersion: install.runtimeVersion,
            scenarios: scenarios,
            options: options,
            runner: runner,
            recordedAtISO8601: now,
            progress: { msg in if !json { print("  \(msg)") } }
        )
        let store = OptimizationProfileStore(root: root)
        for r in results { try store.save(r) }

        if json {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(results), let text = String(data: data, encoding: .utf8) { print(text) }
            return
        }
        print("")
        renderResults(results)
        print("")
        print("Saved \(results.count) result(s). `auto` will now consider validated strategies for this model.")
    }

    // MARK: - compare / reset

    private static func compare(rest: [String], root: PersistenceRoot, json: Bool) throws {
        let positional = rest.filter { !$0.hasPrefix("--") }
        let store = OptimizationProfileStore(root: root)
        let all = store.allResults()
        let results = positional.first.map { model in all.filter { $0.key.modelID == model } } ?? all
        guard !results.isEmpty else {
            print("No benchmark results yet. Run `esh optimize benchmark <model>`.")
            return
        }
        if json {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(results), let text = String(data: data, encoding: .utf8) { print(text) }
            return
        }
        renderResults(results)
    }

    private static func reset(rest: [String], root: PersistenceRoot) throws {
        let positional = rest.filter { !$0.hasPrefix("--") }
        guard let model = positional.first else {
            throw StoreError.invalidManifest("Usage: esh optimize reset <model>")
        }
        guard let context = resolveContext(model: model, root: root) else {
            throw StoreError.invalidManifest("Could not resolve \(model).")
        }
        let key = OptimizationPlanner().profileKey(context: context)
        try OptimizationProfileStore(root: root).reset(key: key)
        print("Cleared benchmark evidence for \(model) on this machine.")
    }

    // MARK: - Helpers

    private static func resolveContext(model: String, root: PersistenceRoot) -> OptimizationContext? {
        let installs = (try? FileModelStore(root: root).listInstalls()) ?? []
        let host = HostMachineProfileService().currentProfile()
        if let install = installs.first(where: { $0.id == model || $0.spec.source.reference == model }) {
            return OptimizationContext(backend: install.spec.backend, modelID: install.id, runtimeVersion: install.runtimeVersion, host: host)
        }
        // Fall back to the recommended catalog to infer backend.
        if let rec = RecommendedModelRegistry().resolve(alias: model) {
            return OptimizationContext(backend: rec.backend, modelID: model, host: host)
        }
        return OptimizationContext(backend: .mlx, modelID: model, host: host)
    }

    private static func renderResults(_ results: [OptimizationBenchmarkResult]) {
        let grouped = Dictionary(grouping: results, by: { "\($0.workload.rawValue) · \($0.contextBucket.rawValue)" })
        for (scenario, group) in grouped.sorted(by: { $0.key < $1.key }) {
            print(scenario)
            print("  strategy          decode    ttft      peak-mem     quality")
            for r in group.sorted(by: { ($0.median.decodeTokensPerSec ?? 0) > ($1.median.decodeTokensPerSec ?? 0) }) {
                let dec = r.median.decodeTokensPerSec.map { String(format: "%.1f t/s", $0) } ?? "-"
                let ttft = r.median.ttftMs.map { String(format: "%.0f ms", $0) } ?? "-"
                let mem = r.median.peakMemoryBytes.map { ByteFormatting.string(for: $0) } ?? "-"
                let q = r.median.qualityScore.map { String(format: "%.2f", $0) } ?? "-"
                print("  \(pad(r.strategyID, 17)) \(pad(dec, 9)) \(pad(ttft, 9)) \(pad(mem, 12)) \(q)")
            }
        }
    }

    private static func printJSON(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }
}
