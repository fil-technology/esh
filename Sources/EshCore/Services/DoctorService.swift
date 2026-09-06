import Foundation

/// Aggregated, machine-readable health report for esh. Produced by `esh doctor` (human + `--json`)
/// so Ashex and other external tooling have a single stable schema for diagnosing the most common
/// installation/runtime failures from one command.
public struct DoctorReport: Codable, Sendable {
    public var status: String            // "ok" | "degraded"
    public var version: String?
    public var macOS: String
    public var host: HostMachineProfile
    public var storage: StorageReport
    public var engines: [EngineStatus]
    public var models: DoctorModelsReport
    public var appleIntelligence: AppleIntelligenceStatus
    public var audio: AudioRuntimeStatus
    public var voice: VoiceRuntimeStatus
    public var stateRoot: String
    public var configPath: String

    public init(
        status: String,
        version: String?,
        macOS: String,
        host: HostMachineProfile,
        storage: StorageReport,
        engines: [EngineStatus],
        models: DoctorModelsReport,
        appleIntelligence: AppleIntelligenceStatus,
        audio: AudioRuntimeStatus,
        voice: VoiceRuntimeStatus,
        stateRoot: String,
        configPath: String
    ) {
        self.status = status
        self.version = version
        self.macOS = macOS
        self.host = host
        self.storage = storage
        self.engines = engines
        self.models = models
        self.appleIntelligence = appleIntelligence
        self.audio = audio
        self.voice = voice
        self.stateRoot = stateRoot
        self.configPath = configPath
    }
}

/// Voice 2.1 realtime stack observability (spec §7). All fields are derived by PURE, on-disk / in-process
/// probes — no server is started and no model is loaded — so `esh doctor` stays fast and side-effect free.
/// warm/cold and per-session latencies are measured live via `voice-ws-bench`; here we report the static
/// configuration a session WOULD start with.
public struct VoiceRuntimeStatus: Codable, Sendable {
    public var websocketPath: String          // "/v1/voice/stream"
    public var defaultEndpoint: String        // ws URL on the companion port (serve port + 1)
    public var vadProvider: String            // server-side endpointer
    public var sttModel: String               // configured or runtime default
    public var autoSelectedLLM: String?       // Voice Auto pick over installed MLX models (nil = none fits)
    public var voiceAutoReason: String?
    public var ttsModel: String?              // configured TTS default
    public var voiceFitClass: String?         // combined whole-stack Fit for the selected LLM
    public var voiceFitReason: String?
    public var warmState: String              // "static (no live session at doctor time)"
    public var offlineReady: Bool             // STT+LLM+TTS all resolvable locally → a turn can run offline
    public var managedStorageRoot: String
    public init(websocketPath: String, defaultEndpoint: String, vadProvider: String, sttModel: String,
                autoSelectedLLM: String?, voiceAutoReason: String?, ttsModel: String?,
                voiceFitClass: String?, voiceFitReason: String?, warmState: String,
                offlineReady: Bool, managedStorageRoot: String) {
        self.websocketPath = websocketPath; self.defaultEndpoint = defaultEndpoint
        self.vadProvider = vadProvider; self.sttModel = sttModel
        self.autoSelectedLLM = autoSelectedLLM; self.voiceAutoReason = voiceAutoReason
        self.ttsModel = ttsModel; self.voiceFitClass = voiceFitClass; self.voiceFitReason = voiceFitReason
        self.warmState = warmState; self.offlineReady = offlineReady; self.managedStorageRoot = managedStorageRoot
    }
}

/// State of the generative-audio backends. SFX (AudioGen) runs in an ISOLATED Python runtime kept off the
/// main venv; music (MusicGen) runs in the bridge. Both cache weights under the assets root (SSD), never the
/// internal HF cache. Reported so the neural audio provider is observable and installable as first-class.
public struct AudioRuntimeStatus: Codable, Sendable {
    /// Path to the isolated AudioGen venv python, if discoverable (env override or a known managed path).
    public var isolatedRuntimePath: String?
    public var sfxModelInstalled: Bool     // facebook/audiogen-medium present under the assets cache
    public var musicModelInstalled: Bool   // facebook/musicgen-small present under the assets cache

    public init(isolatedRuntimePath: String?, sfxModelInstalled: Bool, musicModelInstalled: Bool) {
        self.isolatedRuntimePath = isolatedRuntimePath
        self.sfxModelInstalled = sfxModelInstalled
        self.musicModelInstalled = musicModelInstalled
    }
}

public struct DoctorModelsReport: Codable, Sendable {
    public var installedCount: Int
    /// Ids of installs whose payload directory is missing or empty (interrupted/corrupt installs).
    public var incomplete: [String]
    public var defaultModel: String?

    public init(installedCount: Int, incomplete: [String], defaultModel: String?) {
        self.installedCount = installedCount
        self.incomplete = incomplete
        self.defaultModel = defaultModel
    }
}

public struct DoctorService: Sendable {
    public init() {}

    public func report(root: PersistenceRoot, version: String?) -> DoctorReport {
        let engines = (try? EngineOrchestratorService(root: root).listEngines()) ?? []
        let requiredReady = engines.filter(\.required).allSatisfy(\.ready)

        let storage = StorageService().report(root: root)
        let models = modelsReport(root: root)

        // Degraded if a required engine is down OR the configured assets volume is unavailable.
        let storageOK = storage.status != "unavailable"
        let status = (requiredReady && storageOK) ? "ok" : "degraded"

        return DoctorReport(
            status: status,
            version: version,
            macOS: Self.macOSVersionString(),
            host: HostMachineProfileService().currentProfile(),
            storage: storage,
            engines: engines,
            models: models,
            appleIntelligence: AppleIntelligenceService().status(),
            audio: audioRuntimeStatus(root: root),
            voice: voiceRuntimeStatus(root: root, storage: storage),
            stateRoot: root.stateRootURL.path,
            configPath: root.stateRootURL.appendingPathComponent("config.toml").path
        )
    }

    private func modelsReport(root: PersistenceRoot) -> DoctorModelsReport {
        let store = FileModelStore(root: root)
        // If the assets volume is unavailable we cannot enumerate installs reliably; report 0
        // rather than guessing.
        let installs = (try? store.listInstalls()) ?? []
        let fileManager = FileManager.default
        var incomplete: [String] = []
        for install in installs {
            let path = install.installPath
            var isDir: ObjCBool = false
            let exists = fileManager.fileExists(atPath: path, isDirectory: &isDir)
            let empty = ((try? fileManager.contentsOfDirectory(atPath: path))?.isEmpty ?? true)
            if !exists || !isDir.boolValue || empty {
                incomplete.append(install.id)
            }
        }
        let defaultModel = (try? RoutingConfigurationStore(root: root).load())?.mainModel
        return DoctorModelsReport(
            installedCount: installs.count,
            incomplete: incomplete,
            defaultModel: defaultModel
        )
    }

    /// Probe the generative-audio backends: is the isolated SFX runtime discoverable, and are the model
    /// weights cached under the assets root? Pure on-disk / env checks — no downloads, no subprocess.
    private func audioRuntimeStatus(root: PersistenceRoot) -> AudioRuntimeStatus {
        let fm = FileManager.default
        var isolated: String?
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["ESH_AUDIOGEN_PYTHON"], !env.isEmpty {
            candidates.append(env)
        }
        candidates.append("/Volumes/Sviat SSD/esh-runtime/audio/audiogen-mlx/venv/bin/python")
        candidates.append((NSHomeDirectory() as NSString).appendingPathComponent(".esh/runtime/audio/audiogen-mlx/venv/bin/python"))
        for c in candidates where fm.fileExists(atPath: c) { isolated = c; break }

        let audioCache = root.cachesURL.appendingPathComponent("audio-models/hub", isDirectory: true)
        let sfx = fm.fileExists(atPath: audioCache.appendingPathComponent("models--facebook--audiogen-medium").path)
        let music = fm.fileExists(atPath: audioCache.appendingPathComponent("models--facebook--musicgen-small").path)
        return AudioRuntimeStatus(isolatedRuntimePath: isolated, sfxModelInstalled: sfx, musicModelInstalled: music)
    }

    /// Voice 2.1 realtime stack — pure probes only (config + installed models + Fit math). No server, no load.
    private func voiceRuntimeStatus(root: PersistenceRoot, storage: StorageReport) -> VoiceRuntimeStatus {
        let config = try? EshConfigStore().load()
        let host = HostMachineProfileService().currentProfile()
        let installs = (try? FileModelStore(root: root).listInstalls()) ?? []
        let mlx = installs.filter { $0.spec.backend == .mlx }
            .map { (id: $0.id, weightsGB: Double($0.sizeBytes) / 1_000_000_000) }
        let auto = VoiceAuto.selectLLM(installed: mlx, pinned: nil, host: host)

        var fitClass: String?
        var fitReason: String?
        if let auto, let picked = mlx.first(where: { $0.id == auto.id }) {
            let fit = VoiceFit.assess(VoiceFitInput(llmWeightsGB: picked.weightsGB), host: host)
            fitClass = fit.fitClass.rawValue
            fitReason = fit.reason
        }

        let stt = (config?.defaults.sttModel).flatMap { $0.isEmpty ? nil : $0 } ?? "parakeet (runtime default)"
        let tts = (config?.defaults.ttsModel).flatMap { $0.isEmpty ? nil : $0 }
        // A turn can run fully offline iff STT (local runtime), an LLM (auto pick), and a TTS model are all
        // resolvable locally. STT is a bundled local runtime; the gating unknowns are LLM + TTS.
        let offlineReady = (auto != nil) && (tts != nil)

        return VoiceRuntimeStatus(
            websocketPath: "/v1/voice/stream",
            // Companion port = serve port + 1 (default serve 11435 → 11436).
            defaultEndpoint: "ws://127.0.0.1:11436/v1/voice/stream",
            vadProvider: "EnergyVAD (server-side energy endpointer, trailing-silence)",
            sttModel: stt,
            autoSelectedLLM: auto?.id,
            voiceAutoReason: auto?.reason,
            ttsModel: tts,
            voiceFitClass: fitClass,
            voiceFitReason: fitReason,
            warmState: "static (no live session at doctor time; measure warm via voice-ws-bench)",
            offlineReady: offlineReady,
            managedStorageRoot: storage.assetsRoot
        )
    }

    public static func macOSVersionString() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
