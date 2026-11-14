import Foundation
import Testing
import EshCore
@testable import EshRuntime
@testable import EshMacCapabilities

// The validated model catalog: decoding, descriptor exposure, known-good defaults in bridge requests, live
// per-model readiness/fit, the facade entry point, and the Phase-0 provisioning contract (Kokoro deps).

private final class StateHost: CompatibilityEngineHost, @unchecked Sendable {
    let state: CompatibilityEngineState
    init(_ state: CompatibilityEngineState) { self.state = state }
    func inspect(_ manifest: CompatibilityEngineManifest) async -> CompatibilityEngineState { state }
    func install(_ manifest: CompatibilityEngineManifest, onProgress: @Sendable @escaping (Double) -> Void) async throws {}
    func repair(_ manifest: CompatibilityEngineManifest) async throws {}
    func run(_ manifest: CompatibilityEngineManifest, _ request: ResolvedExecutionRequest,
             context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> { AsyncThrowingStream { $0.finish() } }
}

/// A model-aware host whose per-model answers are scripted.
private final class ModelHost: CompatibilityModelHost, @unchecked Sendable {
    let answers: [String: ModelOptionReadiness]
    private let lock = NSLock()
    private var _prepared: [String] = []
    var prepared: [String] { lock.lock(); defer { lock.unlock() }; return _prepared }
    init(_ answers: [String: ModelOptionReadiness]) { self.answers = answers }
    func inspect(_ manifest: CompatibilityEngineManifest) async -> CompatibilityEngineState { .ready }
    func install(_ manifest: CompatibilityEngineManifest, onProgress: @Sendable @escaping (Double) -> Void) async throws {}
    func repair(_ manifest: CompatibilityEngineManifest) async throws {}
    func run(_ manifest: CompatibilityEngineManifest, _ request: ResolvedExecutionRequest,
             context: ExecutionContext) -> AsyncThrowingStream<CapabilityEvent, Error> {
        AsyncThrowingStream { $0.yield(.done(finishReason: "stop")); $0.finish() }
    }
    func inspectModels(_ manifest: CompatibilityEngineManifest, options: [CapabilityModelOption]) async -> [String: ModelOptionReadiness] {
        answers
    }
    func prepareModel(_ manifest: CompatibilityEngineManifest, modelID: String) async throws {
        lock.withLock { _prepared.append(modelID) }
    }
}

private let gib: Int64 = 1_073_741_824

private func entryJSON(_ id: String, engine: String = "mlx-speech-tts", capability: String = "audio.synthesizeSpeech",
                       rank: Int, status: String = "ok", isDefault: Bool = false, peak: Int64? = 2 * 1_073_741_824,
                       args: [String: String] = [:], extras: [[String: String]] = [], error: String? = nil) -> [String: Any] {
    var e: [String: Any] = [
        "id": id, "capability": capability, "engine": engine, "family": "fam", "displayName": id, "rank": rank,
        "isDefault": isDefault, "status": status, "extraPackages": extras, "requiredArgs": args,
        "weightBytes": 400_000_000, "firstRunDownloadBytes": 350_000_000, "auxiliaryDownloads": [],
        "license": "apache-2.0", "commercialUse": true, "sampleOutputOK": status == "ok",
        "lastValidated": ["date": "2026-11-13", "machine": "Apple M1 Pro, 32 GB", "python": "3.11.14",
                          "mlxAudio": "0.6.5", "mlx": "0.32.4"],
    ]
    if let peak { e["peakMemoryBytes"] = peak }
    if let error { e["error"] = error }
    return e
}

private func catalog(_ entries: [[String: Any]]) throws -> ValidatedModelCatalog {
    let doc: [String: Any] = ["schemaVersion": 1, "updatedAt": "2026-11-13",
                              "generatedWith": ["mlxAudio": "0.6.5"], "entries": entries]
    return try ValidatedModelCatalog.decode(JSONSerialization.data(withJSONObject: doc))
}

private func tts() -> CompatibilityEngineManifest { MacCapabilities.manifests().first { $0.id == .speechSynthesize }! }
private func stt() -> CompatibilityEngineManifest { MacCapabilities.manifests().first { $0.id == .speechTranscribe }! }

private func fixture() throws -> ValidatedModelCatalog {
    try catalog([
        entryJSON("org/kokoro", rank: 1, isDefault: true, args: ["voice": "af_heart", "language": "a"],
                  extras: [["module": "misaki", "pip": "misaki>=0.9.4"]]),
        entryJSON("org/big", rank: 2, peak: 40 * gib),
        entryJSON("org/gated", rank: 3, status: "failed", error: "needs access to the gated Hugging Face repo 'x/y'"),
        entryJSON("org/whisper", engine: "mlx-speech-stt", capability: "audio.transcribe", rank: 1, isDefault: true),
    ])
}

@Suite struct ValidatedModelCatalogTests {

    // MARK: catalog decoding + selection

    @Test func decodesAndSelectsPerEngine() throws {
        let c = try fixture()
        #expect(c.entries(engine: .speechSynthesize).map(\.id) == ["org/kokoro", "org/big", "org/gated"])
        #expect(c.entries(capability: .audioTranscribe).map(\.id) == ["org/whisper"])
        #expect(c.defaultEntry(engine: .speechSynthesize)?.id == "org/kokoro")
        #expect(c.entry(id: "org/gated", engine: .speechSynthesize)?.validationStatus == .failed)
        // The consumer option is Python-free and carries the validation stamp.
        let opt = try #require(c.entry(id: "org/kokoro", engine: .speechSynthesize)?.modelOption)
        #expect(opt.isDefault && opt.isRunnable)
        #expect(opt.defaultOptions["voice"] == "af_heart")
        #expect(opt.validatedWith?.contains("mlx-audio 0.6.5") == true)
        #expect(c.entry(id: "org/gated", engine: .speechSynthesize)?.modelOption.validationError?.contains("gated") == true)
    }

    @Test func failedEntryIsNeverTheDefault() throws {
        let c = try catalog([entryJSON("org/a", rank: 1, status: "failed", isDefault: true), entryJSON("org/b", rank: 2)])
        #expect(c.defaultEntry(engine: .speechSynthesize)?.id == "org/b")
        #expect(c.modelOptions(engine: .speechSynthesize).first { $0.id == "org/a" }?.isDefault == false)
    }

    // MARK: descriptor exposure

    @Test func speechDescriptorsCarryValidatedOptionsOthersDoNot() throws {
        let c = try fixture()
        let ttsDesc = CompatibilityCapabilityProvider(manifest: tts(), host: StateHost(.ready), supported: true, catalog: c).descriptor
        #expect(ttsDesc.modelOptions.map(\.id) == ["org/kokoro", "org/big", "org/gated"])
        let music = MacCapabilities.manifests().first { $0.id == .music }!
        #expect(CompatibilityCapabilityProvider(manifest: music, host: StateHost(.ready), supported: true, catalog: c)
            .descriptor.modelOptions.isEmpty)
    }

    // MARK: known-good defaults in the bridge request

    @Test func bridgeRequestAppliesKnownGoodDefaultsButCallerWins() throws {
        let c = try fixture()
        let root = PersistenceRoot(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        func request(_ options: [String: JSONValue]) -> ResolvedExecutionRequest {
            ResolvedExecutionRequest(request: ExecutionRequest(capability: .audioSynthesizeSpeech, inputs: [.text("hi")],
                                                               output: OutputSpec(modality: .audio),
                                                               options: ExecutionOptions(options)))
        }
        let d = try #require(try JSONSerialization.jsonObject(with: EshManagedPythonHost.bridgeRequest(
            .speechSynthesize, request([:]), outputPath: "/tmp/s.wav", root: root, catalog: c)) as? [String: Any])
        #expect(d["model"] as? String == "org/kokoro")          // catalog default
        #expect(d["voice"] as? String == "af_heart")            // Kokoro REQUIRES a voice — filled in
        #expect(d["language"] as? String == "a")
        let o = try #require(try JSONSerialization.jsonObject(with: EshManagedPythonHost.bridgeRequest(
            .speechSynthesize, request(["voice": .string("bf_emma")]), outputPath: "/tmp/s.wav", root: root, catalog: c)) as? [String: Any])
        #expect(o["voice"] as? String == "bf_emma")             // explicit option wins
        let other = try #require(try JSONSerialization.jsonObject(with: EshManagedPythonHost.bridgeRequest(
            .speechSynthesize, request(["model": .string("org/big")]), outputPath: "/tmp/s.wav", root: root, catalog: c)) as? [String: Any])
        #expect(other["voice"] == nil)                          // no defaults leak across models
    }

    // MARK: live readiness + fit

    @Test func fitJudgment() {
        #expect(ModelOptionAvailability.fit(peakMemoryBytes: 2 * gib, physicalMemoryBytes: 32 * gib) == .comfortable)
        #expect(ModelOptionAvailability.fit(peakMemoryBytes: 10 * gib, physicalMemoryBytes: 16 * gib) == .tight)
        #expect(ModelOptionAvailability.fit(peakMemoryBytes: 14 * gib, physicalMemoryBytes: 16 * gib) == .exceeds)
        #expect(ModelOptionAvailability.fit(peakMemoryBytes: nil, physicalMemoryBytes: 16 * gib) == .unknown)
    }

    @Test func readinessCombinesValidationFitAndHostProbe() async throws {
        let c = try fixture()
        let host = ModelHost(["org/kokoro": .downloadRequired(bytes: 350_000_000), "org/big": .ready])
        let p = CompatibilityCapabilityProvider(manifest: tts(), host: host, supported: true, catalog: c,
                                                physicalMemoryBytes: 32 * gib)
        let rows = Dictionary(uniqueKeysWithValues: await p.modelOptionAvailability(for: .audioSynthesizeSpeech).map { ($0.option.id, $0) })
        let kokoro = try #require(rows["org/kokoro"])
        #expect(kokoro.readiness == .downloadRequired(bytes: 350_000_000))
        #expect(kokoro.fit == .comfortable)
        #expect(kokoro.sizeBytes == 350_000_000)
        #expect(kokoro.note.hasPrefix("Download"))
        #expect(kokoro.providerID == "compat-mlx-speech-tts")
        // 40 GB peak on a 32 GB Mac → unsupported on this machine, regardless of the host saying ready.
        if case .unsupportedOnThisMachine = try #require(rows["org/big"]).readiness {} else { Issue.record("expected unsupportedOnThisMachine") }
        // A model that failed validation is reported but never runnable.
        if case .notValidated(let r) = try #require(rows["org/gated"]).readiness { #expect(r.contains("failed")) }
        else { Issue.record("expected notValidated") }
        // Other capabilities → nothing.
        #expect(await p.modelOptionAvailability(for: .audioTranscribe).isEmpty)
    }

    @Test func readinessFallsBackToEngineStateForPlainHosts() async throws {
        let p = CompatibilityCapabilityProvider(manifest: tts(), host: StateHost(.repairRequired(reason: "missing module 'misaki'")),
                                                supported: true, catalog: try fixture(), physicalMemoryBytes: 32 * gib)
        let kokoro = try #require(await p.modelOptionAvailability(for: .audioSynthesizeSpeech).first { $0.option.id == "org/kokoro" })
        #expect(kokoro.readiness == .needsSetup(reason: "missing module 'misaki'"))
        let off = CompatibilityCapabilityProvider(manifest: tts(), host: StateHost(.ready), supported: false, catalog: try fixture())
        #expect(await off.modelOptionAvailability(for: .audioSynthesizeSpeech).allSatisfy { $0.readiness == .unsupportedOnPlatform })
    }

    @Test func executePreparesTheSelectedModel() async throws {
        let host = ModelHost([:])
        let p = CompatibilityCapabilityProvider(manifest: tts(), host: host, supported: true, catalog: try fixture())
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let ctx = ExecutionContext(root: PersistenceRoot(rootURL: tmp), artifactStore: FileArtifactStore(root: PersistenceRoot(rootURL: tmp)))
        try await withEnv(["ESH_DISABLE_COMPAT_RESOURCE_PREFLIGHT": "1"]) {
            let req = ResolvedExecutionRequest(request: ExecutionRequest(capability: .audioSynthesizeSpeech, inputs: [.text("hi")],
                                                                         output: OutputSpec(modality: .audio)))
            for try await _ in p.execute(req, context: ctx) {}
        }
        #expect(host.prepared == ["org/kokoro"])                // default model's extras ensured before the run
    }

    @Test func facadeListsModelOptions() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let runtime = await EshRuntime.makeDefault(backends: [:], root: PersistenceRoot(rootURL: tmp),
                                                   additionalProviders: MacCapabilities.providers(host: StateHost(.ready)))
        let rows = await runtime.modelOptions(for: .audioSynthesizeSpeech)
        let bundled = ValidatedModelCatalog.bundled().entries(engine: .speechSynthesize)
        #expect(rows.count == bundled.count)
        #expect(rows.allSatisfy { $0.providerID == "compat-mlx-speech-tts" })
        #expect(await runtime.modelOptions(for: .musicGenerate).isEmpty)
    }

    // MARK: the shipped catalog (produced by scripts/model-catalog/validate.py)

    @Test func shippedCatalogHasValidatedSpeechDefaults() throws {
        let c = ValidatedModelCatalog.bundled()
        #expect(c.schemaVersion == 1)
        for engine in [CompatibilityEngineID.speechSynthesize, .speechTranscribe] {
            let def = try #require(c.defaultEntry(engine: engine), "no validated default for \(engine.rawValue)")
            #expect(def.validationStatus == .ok && def.sampleOutputOK)
        }
        #expect(c.defaultEntry(engine: .speechSynthesize)?.requiredArgs["voice"] != nil)   // Kokoro needs a voice
        for e in c.entries where e.validationStatus == .ok {
            #expect(e.sampleOutputOK, "\(e.id) ok without a passing sample")
            #expect(e.peakMemoryBytes != nil && e.firstRunDownloadBytes != nil, "\(e.id) missing observed facts")
            #expect(!e.lastValidated.date.isEmpty)
        }
        // Every runnable model's extra packages are provisionable by the engine (the default's are part of the
        // engine manifest itself, so a bare install can run it).
        let ttsModules = Set(tts().requiredModules.map(\.module))
        for pkg in c.defaultEntry(engine: .speechSynthesize)?.extraPackages ?? [] {
            #expect(ttsModules.contains(pkg.module), "default TTS needs \(pkg.module) but the manifest doesn't provision it")
        }
    }

    // MARK: Phase-0 provisioning contract

    @Test func ttsManifestProvisionsKokoroG2PWithoutTorch() {
        let mods = Dictionary(uniqueKeysWithValues: tts().requiredModules.map { ($0.module, $0.pipPackage) })
        for m in ["mlx_audio", "misaki", "espeakng_loader", "phonemizer", "num2words", "spacy", "en_core_web_sm"] {
            #expect(mods[m] != nil, "TTS provisioning must install \(m)")
        }
        #expect(mods["phonemizer"] == "phonemizer-fork")                     // misaki needs the fork, not upstream
        #expect(mods["en_core_web_sm"]?.contains("en_core_web_sm-3.8.0") == true)  // pinned wheel, no runtime download
        #expect(mods["torch"] == nil)                                        // misaki[en]'s curated-transformers not needed
        #expect(mods["mlx_audio"] == MacCapabilities.mlxAudioRequirement)    // pinned to the validated line
        #expect(Set(stt().requiredModules.map(\.module)).contains("mlx_audio"))
    }
}

private func withEnv(_ vars: [String: String], _ body: () async throws -> Void) async rethrows {
    let old = vars.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
    for (k, v) in vars { setenv(k, v, 1) }
    defer { for (k, v) in old { if let v { setenv(k, v, 1) } else { unsetenv(k) } } }
    try await body()
}
