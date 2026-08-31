import Foundation
import EshCore

/// `esh benchmark lab [--all | <model-id> ...] [--json]`
/// Runs the Model Benchmark Lab over installed models using esh's own inference path, stores versioned
/// local evidence, and prints a profile-oriented summary.
enum BenchmarkLabCommand {
    static func run(arguments: [String], root: PersistenceRoot) async throws {
        let json = arguments.contains("--json")
        let all = arguments.contains("--all")
        let explicitIDs = arguments.filter { !$0.hasPrefix("--") }

        let modelStore = FileModelStore(root: root)
        let installs = try modelStore.listInstalls()
        guard !installs.isEmpty else {
            throw StoreError.notFound("No installed models to benchmark. Install one with `esh model install`.")
        }
        let targets: [ModelInstall]
        if all || explicitIDs.isEmpty {
            targets = installs
        } else {
            targets = installs.filter { explicitIDs.contains($0.id) || explicitIDs.contains($0.spec.source.reference) }
            guard !targets.isEmpty else {
                throw StoreError.notFound("None of the requested models are installed: \(explicitIDs.joined(separator: ", "))")
            }
        }

        let inference = ExternalInferenceService(
            modelStore: modelStore,
            sessionStore: FileSessionStore(root: root),
            cacheStore: FileCacheStore(root: root)
        )
        let host = HostMachineProfileService().currentProfile()
        let hardware = "\(host.chipDescription ?? "Apple Silicon") / \(host.totalMemoryGB.map { "\(Int($0)) GB" } ?? "unknown")"

        let lab = ModelBenchmarkLabService(hardware: hardware, eshVersion: AppVersionResolver.currentVersion()) { install, prompt, maxTokens in
            let request = ExternalInferenceRequest(
                model: install.id,
                messages: [ExternalInferenceMessage(role: .user, text: prompt)],
                generation: GenerationConfig(maxTokens: maxTokens, temperature: 0)
            )
            let response = try await inference.infer(request: request)
            return (response.outputText, response.metrics)
        }

        if !json { FileHandle.standardError.write(Data("Benchmarking \(targets.count) model(s) on \(hardware)…\n".utf8)) }
        var evidence: [ModelBenchmarkEvidence] = []
        for install in targets {
            if !json { FileHandle.standardError.write(Data("  • \(install.id)…\n".utf8)) }
            evidence.append(await lab.benchmark(install: install))
        }

        let dataset = try ModelBenchmarkLabStore(root: root).upsert(evidence)

        if json {
            let data = try JSONCoding.encoder.encode(dataset)
            print(String(decoding: data, as: UTF8.self))
        } else {
            printSummary(evidence)
        }
    }

    private static func printSummary(_ evidence: [ModelBenchmarkEvidence]) {
        func pad(_ s: String, _ w: Int) -> String {
            s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
        }
        print("")
        print(pad("model", 44) + pad("ttft", 9) + pad("tok/s", 8) + pad("mem MB", 9) + pad("quality", 9) + "stable")
        for e in evidence.sorted(by: { ($0.performance.decodeTokensPerSecondMedian ?? 0) > ($1.performance.decodeTokensPerSecondMedian ?? 0) }) {
            let p = e.performance
            print(pad(String(e.modelID.prefix(43)), 44)
                + pad(p.ttftMillisecondsMedian.map { String(format: "%.0fms", $0) } ?? "-", 9)
                + pad(p.decodeTokensPerSecondMedian.map { String(format: "%.0f", $0) } ?? "-", 8)
                + pad(p.peakMemoryMB.map { String(format: "%.0f", $0) } ?? "-", 9)
                + pad("\(e.quality.passed)/\(e.quality.total)", 9)
                + (e.stable ? "yes" : "NO"))
        }
        print("\nProfile leaders (local measured evidence):")
        for (label, pick) in profileLeaders(evidence) {
            print("  \(label): \(pick)")
        }
    }

    /// Profile-specific leaders from local evidence (Fast / Low Memory / Reasoning / Coding / Max Quality).
    static func profileLeaders(_ evidence: [ModelBenchmarkEvidence]) -> [(String, String)] {
        guard !evidence.isEmpty else { return [] }
        func best(_ label: String, _ score: (ModelBenchmarkEvidence) -> Double?) -> (String, String)? {
            let ranked = evidence.compactMap { e in score(e).map { (e.modelID, $0) } }.sorted { $0.1 > $1.1 }
            guard let top = ranked.first else { return nil }
            return (label, top.0)
        }
        var out: [(String, String)] = []
        if let x = best("Fast (decode tok/s)") { e in e.performance.decodeTokensPerSecondMedian } { out.append(x) }
        if let x = best("Low Memory") { e in e.performance.peakMemoryMB.map { -$0 } } { out.append(x) }
        if let x = best("Reasoning") { e in e.quality.categoryPassRate["reasoning"] } { out.append(x) }
        if let x = best("Coding") { e in e.quality.categoryPassRate["coding"] } { out.append(x) }
        if let x = best("Maximum Quality") { e in Double(e.quality.passed) } { out.append(x) }
        return out
    }
}
